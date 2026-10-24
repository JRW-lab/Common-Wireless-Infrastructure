function r = paired_compare(hashA, hashB, metric, opts)
% PAIRED_COMPARE  Compare two configurations on the frames they share (common random numbers).
%
%   r = paired_compare(hashA, hashB, metric)
%   r = paired_compare(hashA, hashB, metric, opts)
%
%   Phase 3 step 4 (notes/PER_MACHINE_DB_PLAN.md 6.4; design agreed with the
%   laptop session 2026-10-22). Two points of an opted profile that ran the
%   same frame streams saw the same channel, data and noise in every batch
%   with the same (seed_base, lane, k_start), so their difference has the
%   channel-to-channel variance cancelled. This reads the LIVE batch records
%   of both points from every source (ledger_records; archived batches
%   excluded), pairs them, and reports:
%     - the mean paired difference A - B of the metric's batch means, with
%       a batch-means t interval (df M-1);
%     - the ratio A / B of the frame-weighted means, with an interval from
%       a bootstrap over matched batches: the spread of log R, widened by
%       M/(M-1), with a t quantile (a local RandStream, so it is
%       reproducible and leaves the global generator alone); for a metric
%       named *mse* also its square root (an RMSE ratio);
%     - per-batch counts lower_A (A < B), lower_B (A > B) and ties, which
%       are neutral: whether lower is better depends on the metric (BER
%       yes, throughput no); matched frames, unmatched batches
%       per side, and batches dropped because the metric is missing.
%   Batches are paired only within one code revision per point (code_rev),
%   unless opts says otherwise.
%
%   INPUTS:
%     hashA, hashB  the two points (param_hash)
%     metric        a metric name in the batch deltas, e.g. "BER", "recon_mse"
%     opts          optional struct: dbname, table (default db_target),
%                   code_rev (use only this revision), allow_mixed (pair
%                   across revisions, flagged), level (0.95), nboot (2000),
%                   seed (1), quiet (false), records (a records table to use
%                   instead of reading the stores; for tests)
%
%   OUTPUT:
%     r: struct with M, frames, diff, diff_ci, ratio, ratio_ci, rmse_ratio,
%        rmse_ratio_ci, lower_A, lower_B, ties, unmatched_A, unmatched_B,
%        dropped, code_rev_A, code_rev_B, sources, unreachable, message
%
%   LIMITS: read only. Only opted batches (with a k_start) can pair.

% Options and the records of both points
if nargin < 4, opts = struct(); end
o = @(f, d) opt(opts, f, d);
level = o('level', 0.95); nboot = o('nboot', 2000);
hashA = string(hashA); hashB = string(hashB); metric = char(metric);
r = struct('M', 0, 'frames', 0, 'diff', NaN, 'diff_ci', [NaN NaN], 'ratio', NaN, 'ratio_ci', [NaN NaN], ...
    'rmse_ratio', NaN, 'rmse_ratio_ci', [NaN NaN], 'lower_A', 0, 'lower_B', 0, 'ties', 0, 'unmatched_A', 0, 'unmatched_B', 0, ...
    'dropped', 0, 'code_rev_A', strings(1, 0), 'code_rev_B', strings(1, 0), 'sources', strings(1, 0), 'unreachable', strings(1, 0), 'message', "");
if isfield(opts, 'records')
    L = opts.records;
else
    if ~isfield(opts, 'dbname'), t = db_target(); opts.dbname = t.dbname; opts.table = t.table; end
    [L, info] = ledger_records(opts.dbname, opts.table, [hashA hashB]);
    r.sources = info.sources; r.unreachable = info.unreachable;
end

% Opted batches of each point, within one code revision unless asked otherwise
A = L(L.param_hash == hashA & ~isnan(L.k_start), :);
B = L(L.param_hash == hashB & ~isnan(L.k_start), :);
r.code_rev_A = unique(A.code_rev)'; r.code_rev_B = unique(B.code_rev)';
if isfield(opts, 'code_rev')
    A = A(A.code_rev == string(opts.code_rev), :); B = B(B.code_rev == string(opts.code_rev), :);
elseif (numel(r.code_rev_A) > 1 || numel(r.code_rev_B) > 1) && ~o('allow_mixed', false)
    error('paired_compare:mixedCodeRev', ['A point holds batches from more than one code revision (A: %s; B: %s). ' ...
        'Choose one with opts.code_rev, or pass opts.allow_mixed = true.'], ...
        strjoin(extractBefore(r.code_rev_A + "            ", 13), ', '), strjoin(extractBefore(r.code_rev_B + "            ", 13), ', '));
end

% Match on the frame range: same seed_base, lane and k_start, same size
ka = A.seed_base + "|" + A.lane + "|" + A.k_start + "|" + A.n_frames;
kb = B.seed_base + "|" + B.lane + "|" + B.k_start + "|" + B.n_frames;
[~, ia, ib] = intersect(ka, kb, 'stable');
r.unmatched_A = height(A) - numel(ia); r.unmatched_B = height(B) - numel(ib);
if isempty(ia)
    r.message = sprintf('No common frame ranges (A lanes [%s], B lanes [%s]): nothing to pair.', ...
        strjoin(string(unique(A.lane))', ' '), strjoin(string(unique(B.lane))', ' '));
    report(r, metric, o('quiet', false));
    return
end

% Each matched batch's metric mean on both sides; a batch without the metric is dropped
a = nan(numel(ia), 1); b = a; w = double(A.n_frames(ia));
for m = 1:numel(ia)
    a(m) = metric_of(A.delta(ia(m)), metric);
    b(m) = metric_of(B.delta(ib(m)), metric);
end
keep = ~isnan(a) & ~isnan(b);
r.dropped = nnz(~keep);
a = a(keep); b = b(keep); w = w(keep);
M = numel(a); r.M = M; r.frames = sum(w);
if M == 0
    r.message = "Every matched batch lacks the metric " + metric + ".";
    report(r, metric, o('quiet', false));
    return
end

% Difference: batch-means t interval (equal batch sizes, G3)
d = a - b;
r.diff = mean(d);
if M > 1
    half = t_quantile(1 - (1 - level)/2, M - 1) * std(d) / sqrt(M);
    r.diff_ci = r.diff + [-half half];
end
r.lower_A = nnz(a < b); r.lower_B = nnz(a > b); r.ties = nnz(a == b);

% Ratio of frame-weighted means, bootstrap over matched batches
sb = sum(w .* b);
if sb == 0
    r.message = "The sum of B is 0 over the matched batches: the ratio is undefined.";
else
    r.ratio = sum(w .* a) / sb;
    rs = RandStream('mrg32k3a', 'Seed', o('seed', 1));
    idx = randi(rs, M, M, nboot);
    rb = sum(w(idx) .* a(idx), 1) ./ sum(w(idx) .* b(idx), 1);
    rb = rb(isfinite(rb));
    r.ratio_ci = ratio_interval(rb, r.ratio, w, a, b, level);
    if contains(lower(metric), 'mse')
        r.rmse_ratio = sqrt(r.ratio); r.rmse_ratio_ci = sqrt(r.ratio_ci);
    end
end
report(r, metric, o('quiet', false));
end

function v = opt(opts, f, d)
% An option, or its default.
if isfield(opts, f) && ~isempty(opts.(f)), v = opts.(f); else, v = d; end
end

function x = metric_of(delta, metric)
% A metric's batch mean from a delta (JSON text); NaN when absent.
x = NaN;
if strlength(delta) == 0, return; end
D = jsondecode(char(delta));
if isfield(D, 'metrics') && isfield(D.metrics, metric) && isnumeric(D.metrics.(metric)) && isscalar(D.metrics.(metric))
    x = double(D.metrics.(metric));
end
end

function t = t_quantile(p, df)
% Student t quantile for p > 0.5 without the Statistics Toolbox (through the inverse incomplete beta).
x = betaincinv(2 * (1 - p), df / 2, 0.5);
t = sqrt(df * (1 - x) / x);
end

function ci = ratio_interval(rb, R, w, a, b, level)
% Ratio interval: the bootstrap's spread of log R, widened by M/(M-1), with a t quantile (df M-1). Plain percentile
% and BCa intervals covered only 92% at M = 30 in the synthetic test; this covers 94-95% (notes PER_MACHINE_DB_PLAN 6.5).
M = numel(a);
t = t_quantile(1 - (1 - level)/2, M - 1);
if R > 0 && all(rb > 0)
    sd = std(log(rb)) * sqrt(M / (M - 1));
    ci = R * exp([-1 1] * t * sd);
else
    % A ratio at or below zero has no log scale: the delta method on R itself
    zr = w .* (a - R * b) / mean(w .* b);
    ci = R + [-1 1] * t * std(zr) / sqrt(M);
end
end

function report(r, metric, quiet)
% One printout.
if quiet, return; end
fprintf('paired_compare %s: %d matched batches, %d frames; unmatched A %d, B %d; dropped %d\n', ...
    metric, r.M, r.frames, r.unmatched_A, r.unmatched_B, r.dropped);
if strlength(r.message) > 0, fprintf('  %s\n', r.message); end
if r.M > 0
    fprintf('  A - B = %.4g  CI [%.4g, %.4g];  A/B = %.4g  CI [%.4g, %.4g]', r.diff, r.diff_ci, r.ratio, r.ratio_ci);
    if ~isnan(r.rmse_ratio), fprintf(';  sqrt (RMSE ratio) = %.4g  CI [%.4g, %.4g]', r.rmse_ratio, r.rmse_ratio_ci); end
    fprintf('\n  A lower in %d of %d batches, B lower in %d, ties %d (neutral: lower is better for BER, not for throughput)\n', ...
        r.lower_A, r.M, r.lower_B, r.ties);
end
if ~isempty(r.unreachable), fprintf('  NOT READ: %s\n', strjoin(r.unreachable, '; ')); end
end
