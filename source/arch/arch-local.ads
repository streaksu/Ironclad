--  arch-local.ads: Architecture-specific CPU-local storage.
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

with Scheduler;
with Userland.Process;

package Arch.Local is
   --  Fetch and set the current thread and process.
   function Get_Current_Thread return Scheduler.TID;
   function Get_Current_Process return Userland.Process.Process_Data_Acc;
   procedure Set_Current_Thread (Thread : Scheduler.TID);
   procedure Set_Current_Process (Proc : Userland.Process.Process_Data_Acc);
end Arch.Local;
