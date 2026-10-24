function d = local_state_dir(varargin)
% LOCAL_STATE_DIR  A per-user folder for this computer's local state, outside the synced tree.
%
%   d = local_state_dir()                    the CWS state folder
%   d = local_state_dir('locks', host_id())  a subfolder (made if missing)
%
%   File lane locks are meaningful only on the computer that holds them, so
%   they must not live in the Syncthing-shared tree (laptop review, storage
%   step 6b). The base is (Linux port, 2026-10-22):
%     Windows  %LOCALAPPDATA%/CWS           (unchanged from step 6b)
%     Linux    $XDG_STATE_HOME/cws, else ~/.local/state/cws
%
%   OUTPUT:
%     d: char, the folder, created if it does not exist
%
%   LIMITS: not for anything another computer must read.

% The platform's per-user state base
if ispc
    base = fullfile(getenv('LOCALAPPDATA'), 'CWS');
else
    x = getenv('XDG_STATE_HOME');
    if isempty(x), x = fullfile(getenv('HOME'), '.local', 'state'); end
    base = fullfile(x, 'cws');
end

% The requested subfolder, made on first use
parts = cellfun(@char, varargin, 'UniformOutput', false);
d = fullfile(base, parts{:});
if ~isfolder(d), mkdir(d); end
end
