function h = host_id()
% HOST_ID  This computer's name as the results registry knows it (Windows and Linux).
%
%   h = host_id()
%
%   Every computer writes under its own name: its db_sources.json entry
%   (writer), its Results/<name>/ folder, its hold file HOLD_<name>, its
%   lane locks and the machine column of its ledger. The name is, in order:
%     1. the environment variable CWS_HOST, when set (lets a reimaged or
%        renamed computer keep its registry name; set it before MATLAB
%        starts so parallel workers inherit it);
%     2. COMPUTERNAME (Windows; tests also set it to fake another computer);
%     3. the host name (Linux), without its domain part.
%   It is returned upper-case, as the registry stores writers. On the
%   Windows computers COMPUTERNAME is already upper-case, so every stored
%   name is unchanged (Linux port, 2026-10-22; notes INFRASTRUCTURE_OVERVIEW).
%
%   OUTPUT:
%     h: string, e.g. "DESKTOP-V1PFBM7"
%
%   LIMITS: the host-name lookup uses system(), which thread-pool workers
%   lack; there, set CWS_HOST. Errors (host_id:none) when no name is found.

persistent cached

% An explicit name, then the Windows one (both read every call: tests change them at run time)
h = string(getenv('CWS_HOST'));
if strlength(h) == 0, h = string(getenv('COMPUTERNAME')); end

% Linux: the host name, looked up once per session
if strlength(h) == 0
    if isempty(cached)
        [st, out] = system('hostname');
        out = strtrim(string(out));
        if st ~= 0 || strlength(out) == 0
            error('host_id:none', 'No computer name: set CWS_HOST (or COMPUTERNAME), or check that "hostname" works.');
        end
        cached = extractBefore(out + ".", ".");
    end
    h = cached;
end
h = upper(h);
end
