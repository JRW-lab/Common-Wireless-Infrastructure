function r = store_check(mirror, mode)
% STORE_CHECK  Compare one of this computer's mirrors with its primary store.
%
%   r = store_check(mirror)           full comparison
%   r = store_check(mirror, "quick")  ledger batch count and frame sum only
%
%   Storage step 5 (notes/STORAGE_BACKENDS_PLAN.md). The full check compares,
%   per param_hash, frames (exact), metrics, metrics_n and metrics_aux (to
%   1e-12 relative: MySQL's JSON column rounds doubles by up to 1 ulp, and
%   workers may reach the primary and a mirror in different orders), and the
%   set of batch_uids (exact). The quick check is the cheap test run at the
%   start and end of collection (mirrors_quick_check).
%
%   INPUT:
%     mirror: a machine_stores element of this computer (priority >= 2)
%
%   OUTPUT:
%     r: struct with fields ok (logical), mode, detail (text), and for the
%        full check rows_primary, rows_mirror, uids_primary, uids_mirror.
%
%   LIMITS: read only. The primary may be MySQL, SQLite or text (storage
%   step 6b).

% This computer's primary, connected
if nargin < 2, mode = "full"; end
writer = host_id();
reg = db_registry();
st = machine_stores(reg([reg.role] == "machine" & [reg.writer] == writer));
P = st(1);
ap = store_adapter(P.kind);
if P.kind == "mysql", cp = mysql_login(P.dbname); else, cp = ap.open(P); end
am = store_adapter(mirror.kind);
cm = am.open(mirror);
r = struct('ok', false, 'mode', string(mode), 'detail', "");

% Quick: the ledgers' batch counts and frame sums
[np, fp] = ap.ledger_summary(cp, P.table);
[nm, fm] = am.ledger_summary(cm, mirror.table);
if string(mode) == "quick"
    r.ok = np == nm && fp == fm;
    r.detail = sprintf('primary %d batches / %d frames, mirror %d / %d', np, fp, nm, fm);
    close_mirror(mirror, cm); close_mirror(P, cp);
    return
end

% Full: every row and every batch_uid (a file primary through its adapter, storage step 6b)
if P.kind == "mysql"
    RP = fetch(cp, "SELECT param_hash, metrics, metrics_n, metrics_aux, frames_simulated FROM " + P.table);
    try
        UP = string(fetch(cp, "SELECT batch_uid FROM " + ledger_name(P.table)).batch_uid);
    catch
        UP = strings(0, 1);
    end
else
    RP = ap.load_rows(cp);
    UP = ap.uids(cp);
end
RM = am.load_rows(cm);
UM = am.uids(cm);
close_mirror(mirror, cm); close_mirror(P, cp);
r.rows_primary = height(RP); r.rows_mirror = height(RM);
r.uids_primary = numel(UP); r.uids_mirror = numel(UM);
bad = strings(0, 1);
for i = 1:height(RP)
    h = txt(RP.param_hash(i));
    k = find(string(RM.param_hash) == h, 1);
    if isempty(k) || double(RP.frames_simulated(i)) ~= double(RM.frames_simulated(k)) ...
            || ~close_to(dec(RP.metrics(i)), dec(RM.metrics(k))) || ~close_to(dec(RP.metrics_n(i)), dec(RM.metrics_n(k))) ...
            || ~close_to(dec(RP.metrics_aux(i)), dec(RM.metrics_aux(k)))
        bad(end+1) = h; %#ok<AGROW>
    end
end
uids_ok = isempty(setxor(UP, UM));
r.ok = isempty(bad) && height(RP) == height(RM) && uids_ok;
r.detail = sprintf('%d/%d rows, %d differing; uids %d/%d, sets equal %d', height(RP), height(RM), numel(bad), numel(UP), numel(UM), uids_ok);
end

function close_mirror(s, c)
% Close a SQLite store's file handle.
if s.kind == "sqlite", close(c); end
end

function t = ledger_name(table_name)
% Ledger paired with a results table (the mysql_write rule).
if string(table_name) == "sim_lookup", t = "sim_batches"; else, t = string(table_name) + "_batches"; end
end

function s = txt(v)
% One cell as a string.
if iscell(v), v = v{1}; end
if isempty(v) || (isstring(v) && ismissing(v)), s = ""; else, s = string(v); end
end

function v = dec(x)
% Decode a JSON cell or string; empty or missing gives [].
x = txt(x);
if strlength(x) == 0, v = []; else, v = jsondecode(char(x)); end
end

function t = close_to(a, b)
% Equal structs, numbers compared to 1e-12 relative.
if isstruct(a) && isstruct(b)
    fa = sort(fieldnames(a)); fb = sort(fieldnames(b));
    t = isequal(fa, fb) && all(cellfun(@(f) close_to(a.(f), b.(f)), fa));
elseif isnumeric(a) && isnumeric(b)
    t = isequal(size(a), size(b)) && all(abs(a(:) - b(:)) <= 1e-12 * max(1, abs(a(:))));
else
    t = isequal(a, b);
end
end
