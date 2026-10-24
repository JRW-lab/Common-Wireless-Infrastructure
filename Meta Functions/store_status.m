function S = store_status(writer, key, entry)
% STORE_STATUS  Read, or update, a computer's mirror status file.
%
%   S = store_status(writer)              read Results/<writer>/store_status.json
%   S = store_status(writer, key, entry)  set (entry a struct) or clear (entry [])
%                                         one store's status, then return all
%
%   Mirrors (storage step 5, notes/STORAGE_BACKENDS_PLAN.md) are marked
%   stale here when a write to them fails or a check finds them behind the
%   primary; a stale mirror gets no writes until store_resync rebuilds it.
%   Updates run under the file's own lock and are written to a temporary
%   name and moved over the old file, so parallel workers marking different
%   mirrors keep every flag (laptop review, 2026-10-21).
%
%   key: store_key(store), e.g. "2|sqlite|Results/DESKTOP-V1PFBM7/results.sqlite".
%   S:   struct array with fields key, stale, reason, first_uid, time.
%
%   LIMITS: only the owning computer writes its file (Results/<writer>/).

% The file and its lock
root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
d = fullfile(root, 'Results', char(writer));
f = fullfile(d, 'store_status.json');
if nargin < 2
    S = read_status(f);
    return
end
if ~isfolder(d), mkdir(d); end

% Update under the lock: read, change one key, write to a temporary name, move over
lock = [f '.lock'];
tok = take_lock(lock);
try
    S = read_status(f);
    S = S(~strcmp({S.key}, char(key)));
    if ~isempty(entry)
        entry.key = char(key);
        S(end+1, 1) = fill_entry(entry);
    end
    tmp = [f '.tmp'];
    fid = fopen(tmp, 'w'); fwrite(fid, jsonencode(S), 'char'); fclose(fid);
    movefile(tmp, f, 'f');
catch ME
    give_lock(lock, tok);
    rethrow(ME);
end
give_lock(lock, tok);
end

function S = read_status(f)
% The status entries, or an empty array when the file does not exist.
S = repmat(fill_entry(struct('key', '')), 0, 1);
if ~isfile(f), return; end
raw = jsondecode(fileread(f));
if isempty(raw), return; end
if ~iscell(raw), raw = num2cell(raw); end
for i = 1:numel(raw), S(end+1, 1) = fill_entry(raw{i}); end %#ok<AGROW>
end

function e = fill_entry(e)
% Every status entry carries the same fields.
d = struct('key', '', 'stale', false, 'reason', '', 'first_uid', '', 'time', '');
extra = setdiff(fieldnames(e), fieldnames(d));
if ~isempty(extra)
    error('storage:badStatusEntry', 'A store status entry may hold only key, stale, reason, first_uid and time, not "%s".', extra{1});
end
for f = string(fieldnames(d))'
    if ~isfield(e, f), e.(f) = d.(f); end
end
e = orderfields(e, d);
end

function tok = take_lock(lock)
% Create the lock atomically; a lock older than 60 s is from a crashed updater and is taken aside by rename.
tok = char(new_batch_uid());
attr = javaArray('java.nio.file.attribute.FileAttribute', 0);
none = javaArray('java.lang.String', 0);
t0 = tic;
while true
    try
        java.nio.file.Files.createFile(java.nio.file.Paths.get(lock, none), attr);
        fid = fopen(lock, 'w'); fwrite(fid, tok, 'char'); fclose(fid);
        return
    catch ME
        if ~contains(ME.message, 'FileAlreadyExists'), rethrow(ME); end
    end
    info = dir(lock);
    if ~isempty(info) && seconds(datetime("now") - datetime(info.datenum, "ConvertFrom", "datenum")) > 60
        % Taken aside by rename and deleted only if it is still the lock judged stale; a fresh one is put back
        try
            old = fileread(lock);
            mv = javaArray('java.nio.file.CopyOption', 1); mv(1) = java.nio.file.StandardCopyOption.ATOMIC_MOVE;
            side = sprintf('%s.stale.%d', lock, feature('getpid'));
            java.nio.file.Files.move(java.nio.file.Paths.get(lock, none), java.nio.file.Paths.get(side, none), mv);
            if strcmp(fileread(side), old)
                delete(side);
            else
                java.nio.file.Files.move(java.nio.file.Paths.get(side, none), java.nio.file.Paths.get(lock, none), mv);
            end
        catch
        end
    end
    if toc(t0) > 30, error('storage:statusLock', 'Could not take %s within 30 s.', lock); end
    pause(0.01 + 0.05 * rand());
end
end

function give_lock(lock, tok)
% Release the lock only if it is still ours.
try
    if isfile(lock) && strcmp(fileread(lock), tok), delete(lock); end
catch
end
end
