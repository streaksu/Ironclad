--  arch-mmu.adb: Architecture-specific MMU code.
--  Copyright (C) 2021 streaksu
--
--  This program is free software: you can redistribute it and/or modify
--  it under the terms of the GNU General Public License as published by
--  the Free Software Foundation, either version 3 of the License, or
--  (at your option) any later version.
--
--  This program is distributed in the hope that it will be useful,
--  but WITHOUT ANY WARRANTY; without even the implied warranty of
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--  GNU General Public License for more details.
--
--  You should have received a copy of the GNU General Public License
--  along with this program.  If not, see <http://www.gnu.org/licenses/>.

with Ada.Unchecked_Deallocation;
with System.Address_To_Access_Conversions;
with Interfaces; use Interfaces;
with Arch.Wrappers;
with Arch.Stivale2;
with Memory; use Memory;
with Lib.Panic;
with Lib.Alignment;

package body Arch.MMU is
   --  Object to represent a page map.
   Page_Size_4K : constant := 16#001000#;
   Page_Size_2M : constant := 16#200000#;
   type PML4 is array (1 .. 512) of Unsigned_64
      with Alignment => Page_Size_4K, Size => 512 * 64;
   type PML4_Acc is access all PML4;

   --  Page maps.
   type Page_Map is record
      PML4_Level : PML4;
   end record;
   type Page_Map_Acc is access all Page_Map;

   Kernel_Map : Page_Map_Acc;

   type Address_Components is record
      PML4_Entry : Unsigned_64;
      PML3_Entry : Unsigned_64;
      PML2_Entry : Unsigned_64;
      PML1_Entry : Unsigned_64;
   end record;
   function Get_Address_Components
      (Virtual : Virtual_Address) return Address_Components
   is
      Addr   : constant Unsigned_64 := Unsigned_64 (Virtual);
      PML4_E : constant Unsigned_64 := Addr and Shift_Left (16#1FF#, 39);
      PML3_E : constant Unsigned_64 := Addr and Shift_Left (16#1FF#, 30);
      PML2_E : constant Unsigned_64 := Addr and Shift_Left (16#1FF#, 21);
      PML1_E : constant Unsigned_64 := Addr and Shift_Left (16#1FF#, 12);
   begin
      return (PML4_Entry => Shift_Right (PML4_E, 39),
              PML3_Entry => Shift_Right (PML3_E, 30),
              PML2_Entry => Shift_Right (PML2_E, 21),
              PML1_Entry => Shift_Right (PML1_E, 12));
   end Get_Address_Components;

   function Clean_Entry (Entry_Body : Unsigned_64) return Physical_Address is
      Addr : constant Unsigned_64 := Entry_Body and not 16#FFF#;
   begin
      return Physical_Address (Addr and not Shift_Left (1, 63));
   end Clean_Entry;

   function Get_Next_Level
      (Current_Level       : Physical_Address;
       Index               : Unsigned_64;
       Create_If_Not_Found : Boolean) return Physical_Address
   is
      Entry_Addr : constant Virtual_Address :=
         Current_Level + Memory_Offset + Physical_Address (Index * 8);
      Entry_Body : Unsigned_64 with Address => To_Address (Entry_Addr), Import;
   begin
      --  Check whether the entry is present.
      if (Entry_Body and 1) /= 0 then
         return Clean_Entry (Entry_Body);
      elsif Create_If_Not_Found then
         --  Allocate and put some default flags.
         declare
            New_Entry      : constant PML4_Acc := new PML4;
            New_Entry_Addr : constant Physical_Address :=
               To_Integer (New_Entry.all'Address) - Memory_Offset;
         begin
            Entry_Body := Unsigned_64 (New_Entry_Addr) or 2#111#;
            return New_Entry_Addr;
         end;
      end if;
      return Null_Address;
   end Get_Next_Level;

   function Get_Page_4K
      (Map      : Page_Map_Acc;
       Virtual  : Virtual_Address;
       Allocate : Boolean) return Virtual_Address
   is
      Addr  : constant Address_Components := Get_Address_Components (Virtual);
      Addr4 : constant Physical_Address :=
         To_Integer (Map.PML4_Level'Address) - Memory_Offset;
      Addr3, Addr2, Addr1 : Physical_Address := Null_Address;
   begin
      --  Find the entries.
      Addr3 := Get_Next_Level (Addr4, Addr.PML4_Entry, Allocate);
      if Addr3 = Null_Address then
         goto Error_Return;
      end if;
      Addr2 := Get_Next_Level (Addr3, Addr.PML3_Entry, Allocate);
      if Addr2 = Null_Address then
         goto Error_Return;
      end if;
      Addr1 := Get_Next_Level (Addr2, Addr.PML2_Entry, Allocate);
      if Addr1 = Null_Address then
         goto Error_Return;
      end if;

      return Addr1 + Memory_Offset + (Physical_Address (Addr.PML1_Entry) * 8);

   <<Error_Return>>
      Lib.Panic.Soft_Panic ("Address could not be found");
      return Null_Address;
   end Get_Page_4K;

   function Get_Page_2M
      (Map      : Page_Map_Acc;
       Virtual  : Virtual_Address;
       Allocate : Boolean) return Virtual_Address
   is
      Addr  : constant Address_Components := Get_Address_Components (Virtual);
      Addr4 : constant Physical_Address :=
         To_Integer (Map.PML4_Level'Address) - Memory_Offset;
      Addr3, Addr2 : Physical_Address := Null_Address;
   begin
      --  Find the entries.
      Addr3 := Get_Next_Level (Addr4, Addr.PML4_Entry, Allocate);
      if Addr3 = Null_Address then
         goto Error_Return;
      end if;
      Addr2 := Get_Next_Level (Addr3, Addr.PML3_Entry, Allocate);
      if Addr2 = Null_Address then
         goto Error_Return;
      end if;

      return Addr2 + Memory_Offset + (Physical_Address (Addr.PML2_Entry) * 8);

   <<Error_Return>>
      Lib.Panic.Soft_Panic ("Address could not be found");
      return Null_Address;
   end Get_Page_2M;

   function Is_Loaded (Map : Page_Map_Acc) return Boolean is
      Current : constant Unsigned_64 := Arch.Wrappers.Read_CR3;
      PAddr : constant Integer_Address := To_Integer (Map.PML4_Level'Address);
   begin
      return Current = Unsigned_64 (PAddr - Memory_Offset);
   end Is_Loaded;

   function Flags_To_Bitmap (Perm : Page_Permissions) return Unsigned_16 is
      RW  : constant Unsigned_16 := (if not Perm.Read_Only  then 1 else 0);
      U   : constant Unsigned_16 := (if Perm.User_Accesible then 1 else 0);
      PWT : constant Unsigned_16 := (if Perm.Write_Through  then 1 else 0);
      G   : constant Unsigned_16 := (if Perm.Global         then 1 else 0);
   begin
      return Shift_Left (G,   8) or
             Shift_Left (PWT, 7) or --  PAT.
             Shift_Left (PWT, 3) or --  Cache disable.
             Shift_Left (U,   2) or
             Shift_Left (RW,  1) or
             1;                     --  Present bit.
   end Flags_To_Bitmap;

   package Conv is new System.Address_To_Access_Conversions (Page_Map);

   function Init (Memmap : Arch.Boot_Memory_Map) return Boolean is
      package ST renames Stivale2;
      package C1 is new System.Address_To_Access_Conversions (ST.PMR_Tag);

      package Ali1 is new Lib.Alignment (Integer_Address);
      package Ali2 is new Lib.Alignment (Unsigned_64);

      PMRs : constant access ST.PMR_Tag :=
         C1.To_Pointer (To_Address (ST.Get_Tag (ST.Stivale_Tag, ST.PMR_ID)));
      Flags : constant Page_Permissions := (
         User_Accesible => False,
         Read_Only      => False,
         Executable     => True,
         Global         => True,
         Write_Through  => False
      );
      Hardcoded_Region   : constant := 16#100000000#;
      Success1, Success2 : Boolean;
      Aligned_Addr       : Integer_Address;
      Aligned_Len        : Unsigned_64;
   begin
      --  Initialize the kernel pagemap.
      Kernel_Map   := new Page_Map;
      Kernel_Table := Page_Table (Kernel_Map.all'Address);

      --  Map the first 2 GiB (except 0) to the window and identity mapped.
      --  This is done instead of following the pagemap to ensure that all
      --  I/O and memory tables that may not be in the memmap are mapped.
      Success1 := Map_Range (
         Map            => Kernel_Table,
         Physical_Start => To_Address (Page_Size_4K),
         Virtual_Start  => To_Address (Page_Size_4K),
         Length         => Hardcoded_Region - Page_Size_4K,
         Permissions    => Flags
      );
      Success2 := Map_Range (
         Map            => Kernel_Table,
         Physical_Start => To_Address (Page_Size_4K),
         Virtual_Start  => To_Address (Page_Size_4K + Memory_Offset),
         Length         => Hardcoded_Region - Page_Size_4K,
         Permissions    => Flags
      );
      if not Success1 or not Success2 then
         return False;
      end if;

      --  Map the memmap memory to the memory window.
      for E of Memmap loop
         Aligned_Addr := Ali1.Align_Down (To_Integer (E.Start), Page_Size_4K);
         Aligned_Len  := Ali2.Align_Up (Unsigned_64 (E.Length), Page_Size_4K);
         Success1     := Map_Range (
            Map            => Kernel_Table,
            Physical_Start => To_Address (Aligned_Addr),
            Virtual_Start  => To_Address (Aligned_Addr),
            Length         => Storage_Offset (Aligned_Len),
            Permissions    => Flags
         );
         Success2 := Map_Range (
            Map            => Kernel_Table,
            Physical_Start => To_Address (Aligned_Addr),
            Virtual_Start  => To_Address (Aligned_Addr + Memory_Offset),
            Length         => Storage_Offset (Aligned_Len),
            Permissions    => Flags
         );
         if not Success1 or not Success2 then
            return False;
         end if;
      end loop;

      --  Map PMRs of the kernel.
      --  This will always be mapped, so we can mark them global.
      for E of PMRs.Entries loop
         Aligned_Addr := Ali1.Align_Down (E.Base,   Page_Size_4K);
         Aligned_Len  := Ali2.Align_Up   (E.Length, Page_Size_4K);
         Success1     := Map_Range (
            Map            => Kernel_Table,
            Physical_Start => To_Address (Aligned_Addr - Kernel_Offset),
            Virtual_Start  => To_Address (Aligned_Addr),
            Length         => Storage_Offset (Aligned_Len),
            Permissions    => (
               False,
               (E.Permissions and Arch.Stivale2.PMR_Writable_Mask)    = 0,
               (E.Permissions and Arch.Stivale2.PMR_Executable_Mask) /= 0,
               True,
               False
            )
         );
         if not Success1 then
            return False;
         end if;
      end loop;
      return True;
   end Init;

   function Create_Table return Page_Table is
      Map : constant Page_Map_Acc := new Page_Map;
   begin
      Map.PML4_Level (256 .. 512) := Kernel_Map.PML4_Level (256 .. 512);
      return Page_Table (Conv.To_Address (Conv.Object_Pointer (Map)));
   end Create_Table;

   procedure Destroy_Table (Map : in out Page_Table) is
      procedure F is new Ada.Unchecked_Deallocation (Page_Map, Page_Map_Acc);

      Table : Page_Map_Acc :=
         Page_Map_Acc (Conv.To_Pointer (System.Address (Map)));
   begin
      --  TODO: Free the tables themselves.
      F (Table);
      Map := Page_Table (System.Null_Address);
   end Destroy_Table;

   function Make_Active (Map : Page_Table) return Boolean is
      Table : constant Page_Map_Acc :=
         Page_Map_Acc (Conv.To_Pointer (System.Address (Map)));
      Addr : constant Unsigned_64 := Unsigned_64 (Physical_Address
         (To_Integer (Table.PML4_Level'Address) - Memory_Offset));
   begin
      --  Make the pagemap active on the callee core by writing the top-level
      --  address to CR3.
      if Arch.Wrappers.Read_CR3 /= Addr then
         Arch.Wrappers.Write_CR3 (Addr);
      end if;
      return True;
   end Make_Active;

   function Is_Active (Map : Page_Table) return Boolean is
      Table : constant Page_Map_Acc :=
         Page_Map_Acc (Conv.To_Pointer (System.Address (Map)));
   begin
      return Is_Loaded (Table);
   end Is_Active;

   function Translate_Address
      (Map     : Page_Table;
       Virtual : System.Address) return System.Address
   is
      Table  : constant Page_Map_Acc :=
         Page_Map_Acc (Conv.To_Pointer (System.Address (Map)));
      Addr  : constant Integer_Address := To_Integer (Virtual);
      Addr1 : constant Virtual_Address := Get_Page_2M (Table, Addr, False);
      Addr2 : constant Virtual_Address := Get_Page_4K (Table, Addr, False);
      Searched1 : Unsigned_64 with Address => To_Address (Addr1), Import;
      Searched2 : Unsigned_64 with Address => To_Address (Addr2), Import;
   begin
      if (Shift_Right (Unsigned_64 (Addr1), 7) and 1) /= 0 then
         return To_Address (Clean_Entry (Searched1));
      else
         return To_Address (Clean_Entry (Searched2));
      end if;
   end Translate_Address;

   function Map_Range
      (Map            : Page_Table;
       Physical_Start : System.Address;
       Virtual_Start  : System.Address;
       Length         : Storage_Count;
       Permissions    : Page_Permissions) return Boolean
   is
      Table : constant Page_Map_Acc :=
         Page_Map_Acc (Conv.To_Pointer (System.Address (Map)));
      Flags       : constant Unsigned_16 := Flags_To_Bitmap (Permissions);
      Not_Execute : constant Unsigned_64 :=
         (if not Permissions.Executable then 1 else 0);
      PWT : constant Unsigned_64 :=
         (if Permissions.Write_Through then 1 else 0);

      Virt       : Virtual_Address          := To_Integer (Virtual_Start);
      Phys       : Virtual_Address          := To_Integer (Physical_Start);
      Final_Addr : constant Virtual_Address := Virt + Virtual_Address (Length);
   begin
      if To_Integer (Physical_Start) mod Page_Size_4K /= 0 or
         To_Integer (Virtual_Start)  mod Page_Size_4K /= 0 or
         Length                      mod Page_Size_4K /= 0
      then
         return False;
      end if;

      while (Virt mod Page_Size_2M /= 0 or Phys mod Page_Size_2M /= 0) and
             Virt /= Final_Addr
      loop
         declare
            Addr : constant Virtual_Address := Get_Page_4K (Table, Virt, True);
            Entry_Body : Unsigned_64 with Address => To_Address (Addr), Import;
         begin
            Entry_Body := Unsigned_64 (Phys)  or
                          Unsigned_64 (Flags) or
                          Shift_Left (Not_Execute, 63);
         end;
         Virt := Virt + Page_Size_4K;
         Phys := Phys + Page_Size_4K;
      end loop;
      while Virt < Final_Addr loop
         declare
            Addr : constant Virtual_Address := Get_Page_2M (Table, Virt, True);
            Entry_Body : Unsigned_64 with Address => To_Address (Addr), Import;
         begin
            Entry_Body := Unsigned_64 (Phys)           or
                          Unsigned_64 (Flags)          or
                          Shift_Left (Not_Execute, 63) or
                          Shift_Left (PWT, 12)         or
                          Shift_Left (1, 7);
         end;
         Virt := Virt + Page_Size_2M;
         Phys := Phys + Page_Size_2M;
      end loop;

      return True;
   end Map_Range;

   function Remap_Range
      (Map           : Page_Table;
       Virtual_Start : System.Address;
       Length        : Storage_Count;
       Permissions   : Page_Permissions) return Boolean
   is
      Table : constant Page_Map_Acc :=
         Page_Map_Acc (Conv.To_Pointer (System.Address (Map)));
      Flags       : constant Unsigned_16 := Flags_To_Bitmap (Permissions);
      Not_Execute : constant Unsigned_64 :=
         (if not Permissions.Executable then 1 else 0);
      PWT : constant Unsigned_64 :=
         (if Permissions.Write_Through then 1 else 0);

      Virt : Virtual_Address                := To_Integer (Virtual_Start);
      Final_Addr : constant Virtual_Address := Virt + Virtual_Address (Length);
   begin
      if To_Integer (Virtual_Start) mod Page_Size_4K /= 0 or
         Length                     mod Page_Size_4K /= 0
      then
         return False;
      end if;

      while Virt mod Page_Size_2M /= 0 and Virt /= Final_Addr loop
         declare
            Addr : constant Virtual_Address := Get_Page_4K (Table, Virt, True);
            Entry_Body : Unsigned_64 with Address => To_Address (Addr), Import;
         begin
            Entry_Body := Entry_Body          or
                          Unsigned_64 (Flags) or
                          Shift_Left (Not_Execute, 63);
         end;
         Virt := Virt + Page_Size_4K;
      end loop;
      while Virt < Final_Addr loop
         declare
            Addr : constant Virtual_Address := Get_Page_2M (Table, Virt, True);
            Entry_Body : Unsigned_64 with Address => To_Address (Addr), Import;
         begin
            Entry_Body := Entry_Body                   or
                          Unsigned_64 (Flags)          or
                          Shift_Left (Not_Execute, 63) or
                          Shift_Left (PWT, 12)         or
                          Shift_Left (1, 7);
         end;
         Virt := Virt + Page_Size_2M;
      end loop;

      if Is_Loaded (Table) then
         Flush_Local_TLB (Virtual_Start, Length);
      end if;

      return True;
   end Remap_Range;

   function Unmap_Range
      (Map           : Page_Table;
       Virtual_Start : System.Address;
       Length        : Storage_Count) return Boolean
   is
      Table : constant Page_Map_Acc :=
         Page_Map_Acc (Conv.To_Pointer (System.Address (Map)));

      Virt       : Virtual_Address          := To_Integer (Virtual_Start);
      Final_Addr : constant Virtual_Address := Virt + Virtual_Address (Length);
   begin
      if To_Integer (Virtual_Start) mod Page_Size_4K /= 0 or
         Length                     mod Page_Size_4K /= 0
      then
         return False;
      end if;

      while Virt mod Page_Size_2M /= 0 and Virt /= Final_Addr loop
         declare
            Addr : constant Virtual_Address := Get_Page_4K (Table, Virt, True);
            Entry_Body : Unsigned_64 with Address => To_Address (Addr), Import;
         begin
            Entry_Body := Entry_Body and 0;
         end;
         Virt := Virt + Page_Size_4K;
      end loop;
      while Virt < Final_Addr loop
         declare
            Addr : constant Virtual_Address := Get_Page_2M (Table, Virt, True);
            Entry_Body : Unsigned_64 with Address => To_Address (Addr), Import;
         begin
            Entry_Body := Entry_Body and 0;
         end;
         Virt := Virt + Page_Size_2M;
      end loop;

      if Is_Loaded (Table) then
         Flush_Local_TLB (Virtual_Start, Length);
      end if;

      return True;
   end Unmap_Range;

   procedure Flush_Local_TLB (Addr : System.Address) is
   begin
      Wrappers.Invalidate_Page (To_Integer (Addr));
   end Flush_Local_TLB;

   procedure Flush_Local_TLB (Addr : System.Address; Len : Storage_Count) is
      Curr : Storage_Count := 0;
   begin
      while Curr < Len loop
         Wrappers.Invalidate_Page (To_Integer (Addr + Curr));
         Curr := Curr + Page_Size_4K;
      end loop;
   end Flush_Local_TLB;

   --  TODO: Code this 2 bad boys once the VMM makes use of them.

   procedure Flush_Global_TLBs (Addr : System.Address) is
   begin
      null;
   end Flush_Global_TLBs;

   procedure Flush_Global_TLBs (Addr : System.Address; Len : Storage_Count) is
   begin
      null;
   end Flush_Global_TLBs;
end Arch.MMU;
