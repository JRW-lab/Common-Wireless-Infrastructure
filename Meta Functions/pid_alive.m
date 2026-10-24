function tf = pid_alive(pid)
% PID_ALIVE  Whether a process with this id is running on this computer (Windows and Linux).
%
%   tf = pid_alive(pid)
%
%   Lock files (text-store write locks, file lane locks) hold their owner's
%   process id, and a lock is broken only when that process is gone. This is
%   the one check both platforms use (Linux port, 2026-10-22):
%     Windows  tasklist filtered on the id;
%     Linux    /proc/<pid> exists; elsewhere "kill -0 <pid>".
%
%   INPUT:
%     pid: process id (number)
%
%   OUTPUT:
%     tf: true when the process exists. When the check itself can't run,
%         true, so a lock is never broken on a guess.
%
%   LIMITS: process ids are local, so this only answers for this computer.

% Windows: tasklist prints the id only when the process exists
tf = true;
try
    if ispc
        [~, o] = system(sprintf('tasklist /FI "PID eq %d" /NH', pid));
        tf = contains(o, sprintf(' %d ', pid));
    elseif isfolder('/proc/self')
        tf = isfolder(sprintf('/proc/%d', pid));
    else
        tf = system(sprintf('kill -0 %d 2>/dev/null', pid)) == 0;
    end
catch
end
end
