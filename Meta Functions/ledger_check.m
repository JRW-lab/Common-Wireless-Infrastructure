function [C, summary] = ledger_check(dbname, table_name, opts)
% LEDGER_CHECK  Check every source's batch ledger against its rows. Reports; fixes nothing.
%
%   [C, summary] = ledger_check()                       this computer's target
%   [C, summary] = ledger_check(dbname, table_name)
%   [C, summary] = ledger_check(dbname, table_name, opts)
%
%   Phase 3 step 4 (notes/PER_MACHINE_DB_PLAN.md 6.4 and 6.3a; design agreed
%   with the laptop session 2026-10-22). For each source and each point that
%   has a row or ledger records:
%     unledgered   row frames minus LIVE ledger frames; must be >= 0
%     overlaps     live k ranges [k_start, k_start+n-1] that overlap another
%                  live or ARCHIVED range of the same (seed_base, lane)
%     misaligned   live batches whose (seed_base, lane) group has more than
%                  one n_frames, or whose k_start is off the lane's grid:
%                  mod(k_start - (lane*2^32 + 1), n) ~= 0 (gaps left by
%                  deletes are allowed)
%     dup_uids     batch_uids seen twice among live and archived records
%                  (in any source)
%     code_revs    how many code revisions the point's live batches carry
%   and for this computer's mirrors (not Excel) a full store_check.
%
%   INPUTS:
%     dbname, table_name  as for load_merged (default: db_target)
%     opts                optional struct: quiet (false); records and rows
%                         (tables to check instead of reading the stores;
%                         for tests: records as store_read "records_all"
%                         plus source; rows with source, param_hash,
%                         frames_simulated)
%
%   OUTPUTS:
%     C:       one row per (source, param_hash) with the counts above and ok
%     summary: one line, e.g. "ledger_check: 3 sources, 120 points, 0 problems"
%
%   LIMITS: read only. Sources that can't be read are listed in the summary.

% The caller's source, records live and archived, and every source's rows
if nargin < 3, opts = struct(); end
if nargin < 1 || isempty(dbname), t = db_target(); dbname = t.dbname; table_name = t.table; end
unreach = strings(1, 0);
if isfield(opts, 'records')
    L = opts.records; R = opts.rows;
else
    [L, info] = ledger_records(dbname, table_name, "*", true);
    unreach = info.unreachable;
    R = rows_by_source(dbname, table_name);
end

% Every (source, point) that has a row or records
keys = unique([R.source + "|" + string(R.param_hash); L.source + "|" + L.param_hash]);
n = numel(keys);
C = table(strings(n, 1), strings(n, 1), zeros(n, 1), zeros(n, 1), zeros(n, 1), zeros(n, 1), zeros(n, 1), zeros(n, 1), zeros(n, 1), true(n, 1), ...
    'VariableNames', {'source', 'param_hash', 'row_frames', 'ledger_frames', 'unledgered', 'overlaps', 'misaligned', 'dup_uids', 'code_revs', 'ok'});
allu = L.batch_uid; [uu, ~, j] = unique(allu); dupu = uu(accumarray(j, 1) > 1);
for i = 1:n
    p = split(keys(i), "|"); C.source(i) = p(1); C.param_hash(i) = p(2);
    rr = R(R.source == p(1) & string(R.param_hash) == p(2), :);
    if height(rr) > 0, C.row_frames(i) = double(rr.frames_simulated(1)); end
    Li = L(L.source == p(1) & L.param_hash == p(2), :);
    live = Li(~Li.archived, :);
    C.ledger_frames(i) = sum(live.n_frames);
    C.unledgered(i) = C.row_frames(i) - C.ledger_frames(i);
    [C.overlaps(i), C.misaligned(i)] = range_checks(live, Li(Li.archived, :));
    C.dup_uids(i) = nnz(ismember(Li.batch_uid, dupu));
    C.code_revs(i) = numel(unique(live.code_rev(strlength(live.code_rev) > 0)));
end
C.ok = C.unledgered >= 0 & C.overlaps == 0 & C.misaligned == 0 & C.dup_uids == 0 & C.code_revs <= 1;

% This computer's mirrors, in full
mirror_lines = strings(1, 0);
if ~isfield(opts, 'records')
    mirror_lines = mirror_checks();
end

% One line
bad = nnz(~C.ok) + nnz(startsWith(mirror_lines, "FAIL"));
summary = sprintf('ledger_check: %d sources, %d points, %d problem(s)', numel(unique([C.source; strings(0, 1)])), n, bad);
if ~isempty(unreach), summary = summary + "; NOT READ: " + strjoin(unreach, "; "); end
if ~isempty(mirror_lines), summary = summary + "; mirrors: " + strjoin(mirror_lines, "; "); end
if ~opt(opts, 'quiet', false)
    disp(summary);
    if bad > 0, disp(C(~C.ok, :)); end
end
end

function [nov, nmis] = range_checks(live, arch)
% Overlapping k ranges (live vs live and vs archived) and off-grid live batches, per (seed_base, lane).
nov = 0; nmis = 0;
live = live(~isnan(live.k_start), :); arch = arch(~isnan(arch.k_start), :);
g = unique(live.seed_base + "|" + live.lane);
for q = g'
    in = live.seed_base + "|" + live.lane == q;
    Lg = sortrows(live(in, :), 'k_start');
    Ag = arch(arch.seed_base + "|" + arch.lane == q, :);
    s = Lg.k_start; e = s + Lg.n_frames - 1;

    % Live ranges overlapping each other, then an archived range
    nov = nov + nnz(s(2:end) <= e(1:end-1));
    for x = 1:height(Ag)
        as = Ag.k_start(x); ae = as + Ag.n_frames(x) - 1;
        nov = nov + nnz(s <= ae & e >= as);
    end

    % One batch size per group, and every k_start on the lane's grid
    nb = unique(Lg.n_frames);
    if numel(nb) > 1
        nmis = nmis + height(Lg);
    else
        lane = Lg.lane(1);
        nmis = nmis + nnz(mod(s - (lane * 2^32 + 1), nb) ~= 0);
    end
end
end

function R = rows_by_source(dbname, table_name)
% Every machine source's rows (hash and frames), tagged with the source name; unreachable ones are skipped.
src = db_sources(dbname, table_name);
R = table(strings(0, 1), strings(0, 1), zeros(0, 1), 'VariableNames', {'source', 'param_hash', 'frames_simulated'});
for k = 1:numel(src)
    if src(k).role ~= "machine" && ~src(k).own, continue; end
    try
        if ~isempty(src(k).stores)
            mode = "remote"; if src(k).own, mode = "own"; end
            T = store_read(src(k), "*", mode);
        else
            T = fetch(db_source_conn(src(k)), "SELECT param_hash, frames_simulated FROM " + src(k).table);
        end
    catch
        continue
    end
    R = [R; table(repmat(string(src(k).name), height(T), 1), string(T.param_hash), double(T.frames_simulated), ...
        'VariableNames', {'source', 'param_hash', 'frames_simulated'})]; %#ok<AGROW>
end
end

function lines = mirror_checks()
% A full store_check of each of this computer's mirrors (not Excel).
lines = strings(1, 0);
reg = db_registry();
if isempty(reg), return; end
k = find([reg.role] == "machine" & [reg.writer] == host_id(), 1);
if isempty(k), return; end
st = machine_stores(reg(k));
for j = 2:numel(st)
    if st(j).kind == "excel", continue; end
    try
        r = store_check(st(j));
        if r.ok, lines(end+1) = "ok " + st(j).kind; else, lines(end+1) = "FAIL " + st(j).kind + " (" + r.detail + ")"; end %#ok<AGROW>
    catch ME
        lines(end+1) = "FAIL " + st(j).kind + " (" + string(ME.message) + ")"; %#ok<AGROW>
    end
end
end

function v = opt(opts, f, d)
% An option, or its default.
if isfield(opts, f) && ~isempty(opts.(f)), v = opts.(f); else, v = d; end
end
