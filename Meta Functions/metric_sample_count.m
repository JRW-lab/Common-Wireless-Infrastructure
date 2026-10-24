function n = metric_sample_count(row, metric, stage)
%METRIC_SAMPLE_COUNT  Samples behind each metric of a stored result row.
%
%   n = metric_sample_count(row)
%       struct, one field per metric on the row -> its sample count.
%   n = metric_sample_count(row, metric, stage)
%       scalar: the count that decides whether `metric` at this point needs
%       more samples, for a point collected at `stage` ("full" or a stage a
%       sim_fun stops at early, e.g. "est1"; see metric_stage.m).
%
%   row is one row of a results table as mysql_load returns it (columns
%   metrics, frames_simulated, and metrics_n once mysql_write has added it),
%   or empty.
%
%   THE FORMAT (2026-10-16, see mysql_write's PER-METRIC SAMPLE COUNTS).
%   metrics_n holds metric -> count, plus frames_basis: frames_simulated as
%   it stood when metrics_n was written. This is the one reader of it; the
%   scheduler (sim_head, sim_save) and the merge (mysql_write) both come
%   here, so they cannot disagree about how many samples a metric has.
%
%   ROWS WITHOUT metrics_n (everything written before 2026-10-16): every
%   metric counts frames_simulated, which is what the old blend assumed.
%
%   ROWS AN OLDER WRITER HAS TOUCHED SINCE. A writer that predates metrics_n
%   adds frames and blends every field it reports, but leaves metrics_n
%   alone, and it rebuilds the row from its own batch, dropping any field
%   it does not report. So with gap = frames_simulated - frames_basis > 0:
%     - a field in both metrics and metrics_n gained gap samples;
%     - a field only in metrics was introduced by such a writer, so all its
%       samples are in the gap: it counts gap;
%     - a field only in metrics_n was dropped by such a writer: no count.
%   A NEGATIVE gap means frames_simulated was edited by hand; metrics_n
%   no longer describes the row, and it is read as a pre-2026-10-16 row.
%
%   FULL-FRAME METRICS THE CONFIG NEVER PRODUCES (BER_info on an uncoded
%   config) are absent from the row forever. The scalar form returns
%   frames_simulated for them at stage "full", exactly the count scheduling
%   used before, so such a point is not re-collected endlessly. At an early
%   stage an absent metric counts 0: those frames produce nothing else.

if nargin < 2, metric = ""; end
if nargin < 3, stage = "full"; end

n = struct();
F = 0;
if ~isempty(row) && height(row) > 0
    F = double(row.frames_simulated(1));
    m = decode_json(row.metrics(1));
    fm = fieldnames(m);
    nn = [];
    if ismember('metrics_n', row.Properties.VariableNames)
        nn = decode_json(row.metrics_n(1));
    end
    gap = -1;
    if isstruct(nn) && ~isempty(fieldnames(nn))
        basis = F;
        if isfield(nn, 'frames_basis'), basis = double(nn.frames_basis); end
        gap = F - basis;
    end
    for k = 1:numel(fm)
        f = fm{k};
        if gap < 0
            n.(f) = F;
        elseif isfield(nn, f)
            n.(f) = double(nn.(f)) + gap;
        else
            n.(f) = gap;
        end
    end
end

if strlength(string(metric)) == 0
    return
end
metric = char(metric);
if isfield(n, metric)
    n = n.(metric);
elseif string(stage) == "full"
    n = F;
else
    n = 0;
end
end

function s = decode_json(v)
% A JSON cell of the results table, or [] when missing/NULL/empty.
s = [];
if iscell(v), v = v{1}; end
if isempty(v), return; end
if (isstring(v) || ischar(v)) && (ismissing(string(v)) || strlength(string(v)) == 0)
    return
end
if isstruct(v)
    s = v;
    return
end
s = jsondecode(char(v));
end
