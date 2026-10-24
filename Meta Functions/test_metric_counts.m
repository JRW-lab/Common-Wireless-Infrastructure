function test_metric_counts(varargin)
%TEST_METRIC_COUNTS  Regression test for per-metric sample counts.
%
%   test_metric_counts                 single-process scenarios
%   test_metric_counts('concurrent',N) also two OS processes racing, one
%                                      writing full batches and one writing
%                                      stage-limited batches, N each
%
%   Covers mysql_write's PER-METRIC SAMPLE COUNTS and A WRITE NEVER DELETES
%   A METRIC, and metric_sample_count's reconciliation of rows touched by a
%   writer that predates metrics_n. Every assertion is exact arithmetic.
%
%   Runs against a scratch table it creates and drops; sim_lookup is never
%   touched. Run from a project root (see test_mysql_concurrency).

if nargin >= 1 && isequal(varargin{1}, 'worker')
    run_worker(varargin{2:end});
    return
end
p = inputParser;
p.addParameter('concurrent', 0);
p.addParameter('dbname', 'comm_database');
p.parse(varargin{:});
dbname = p.Results.dbname;
try, addMysqlJarOnce(); catch, end
conn = mysql_login(dbname);
TBL = 'metric_count_test_tbl';
ok = true;

% ---- 1. legacy row (no metrics_n), then a stage-limited batch ----------
fresh_table(conn, TBL, false);
params = struct('testcase', "metric_counts", 'point', 1);
[pj, ph] = jsonencode_sorted(params);
execute(conn, sprintf("INSERT INTO %s (param_hash,parameters,metrics,frames_simulated) VALUES ('%s','%s','%s',100)", ...
    TBL, ph, pj, jsonencode(struct('BER',0.1,'recon_mse',0.05))));
mysql_write(conn, TBL, params, 0, struct('recon_mse_r1',0.2), false, [], [], struct('recon_mse_r1',50));
[m, n, F, seq] = read_row(conn, TBL, ph);
fprintf('\n== 1. legacy row + stage-limited batch ==\n');
ok = chk('frames_simulated', F, 100) && ok;
ok = chk('BER kept', m.BER, 0.1) && ok;
ok = chk('recon_mse kept', m.recon_mse, 0.05) && ok;
ok = chk('recon_mse_r1 seeded', m.recon_mse_r1, 0.2) && ok;
ok = chk('n BER', n.BER, 100) && ok;
ok = chk('n recon_mse_r1', n.recon_mse_r1, 50) && ok;
ok = chk('write_seq', seq, 1) && ok;

% ---- 2. full batch on top: each metric blends against its own count ----
mysql_write(conn, TBL, params, 10, struct('BER',0.2,'recon_mse',0.1,'recon_mse_r1',0.5), false);
[m, n, F, seq] = read_row(conn, TBL, ph);
fprintf('\n== 2. full batch, 7-argument-style call (no metrics_n_add) ==\n');
ok = chk('frames_simulated', F, 110) && ok;
ok = chk('BER', m.BER, (0.1*100 + 0.2*10)/110) && ok;
ok = chk('recon_mse_r1', m.recon_mse_r1, (0.2*50 + 0.5*10)/60) && ok;
ok = chk('n BER', n.BER, 110) && ok;
ok = chk('n recon_mse_r1', n.recon_mse_r1, 60) && ok;
ok = chk('write_seq', seq, 2) && ok;

% ---- 3. an OLD writer adds 10 frames, dropping recon_mse_r1 ------------
% Exactly what the pre-2026-10-16 mysql_write does: rebuild metrics from
% its own batch, frames_simulated += 10, metrics_n and write_seq untouched.
execute(conn, sprintf("UPDATE %s SET metrics = '%s', frames_simulated = 120 WHERE param_hash = '%s'", ...
    TBL, jsonencode(struct('BER',0.3,'recon_mse',0.2)), ph));
T = mysql_load(conn, TBL, ph);
n = metric_sample_count(T);
fprintf('\n== 3. row after an old-code writer ==\n');
ok = chk('n BER (110 + gap 10)', n.BER, 120) && ok;
ok = chk('n recon_mse', n.recon_mse, 120) && ok;
ok = chk('recon_mse_r1 count gone', double(isfield(n,'recon_mse_r1')), 0) && ok;
ok = chk('scalar, est1 metric absent', metric_sample_count(T,'recon_mse_r1','est1'), 0) && ok;
mysql_write(conn, TBL, params, 0, struct('recon_mse_r1',0.3), false, [], [], struct('recon_mse_r1',5));
[m, n, F] = read_row(conn, TBL, ph);
ok = chk('recon_mse_r1 reseeded', m.recon_mse_r1, 0.3) && ok;
ok = chk('n recon_mse_r1', n.recon_mse_r1, 5) && ok;
ok = chk('frames_simulated', F, 120) && ok;
ok = chk('BER untouched', m.BER, 0.3) && ok;

% ---- 4. a new row created by a stage-limited batch --------------------
params2 = struct('testcase', "metric_counts", 'point', 2);
[~, ph2] = jsonencode_sorted(params2);
mysql_write(conn, TBL, params2, 0, struct('recon_mse_r1',0.4), false, [], [], struct('recon_mse_r1',7));
T2 = mysql_load(conn, TBL, ph2);
fprintf('\n== 4. row created by a stage-limited batch ==\n');
ok = chk('frames_simulated', double(T2.frames_simulated(1)), 0) && ok;
ok = chk('count recon_mse_r1 (est1)', metric_sample_count(T2,'recon_mse_r1','est1'), 7) && ok;
ok = chk('count BER (full, absent)', metric_sample_count(T2,'BER','full'), 0) && ok;

% ---- 5. hand-edited frames_simulated (negative gap) --------------------
execute(conn, sprintf("UPDATE %s SET frames_simulated = 3 WHERE param_hash = '%s'", TBL, ph));
n = metric_sample_count(mysql_load(conn, TBL, ph));
fprintf('\n== 5. frames_simulated edited below frames_basis ==\n');
ok = chk('read as legacy: n BER', n.BER, 3) && ok;

try, execute(conn, "DROP TABLE " + TBL); catch, end

% ---- 6. two processes: full and stage-limited batches racing ----------
nB = p.Results.concurrent;
if nB > 0
    fprintf('\n== 6. concurrent: 1 full writer + 1 stage-limited writer, %d batches each ==\n', nB);
    for precreate = [false true]
        fresh_table(conn, TBL, precreate);
        if precreate
            fprintf('  (row pre-seeded, legacy, frames 0)\n');
            execute(conn, sprintf("INSERT INTO %s (param_hash,parameters,metrics,frames_simulated) VALUES ('%s','%s','%s',0)", ...
                TBL, ph, pj, jsonencode(struct('BER',0))));
        else
            fprintf('  (row absent: create race)\n');
        end
        here = fileparts(mfilename('fullpath'));
        mk = @(id) sprintf(['matlab -batch "addpath(''%s''); ' ...
            'test_metric_counts(''worker'',%d,%d,''%s'',''%s'')"'], here, id, nB, TBL, dbname);
        j1 = java.lang.ProcessBuilder({'cmd','/c', mk(1)}).redirectErrorStream(true).start();
        j2 = java.lang.ProcessBuilder({'cmd','/c', mk(2)}).redirectErrorStream(true).start();
        j1.waitFor(); j2.waitFor();
        ok = chk('worker exit codes', double(j1.exitValue() == 0 && j2.exitValue() == 0), 1) && ok;
        [m, n, F] = read_row(conn, TBL, ph);
        ok = chk('frames_simulated', F, nB) && ok;
        ok = chk('n BER', n.BER, nB) && ok;
        ok = chk('n recon_mse_r1', n.recon_mse_r1, 2*nB) && ok;
        ok = chk('BER mean', m.BER, 0.001) && ok;
        ok = chk('recon_mse_r1 mean', m.recon_mse_r1, 2.0) && ok;
    end
    try, execute(conn, "DROP TABLE " + TBL); catch, end
end

fprintf('\n%s\n', repmat('=', 1, 58));
if ok
    fprintf('TEST_METRIC_COUNTS: ALL PASS\n');
else
    error('test_metric_counts:failed', 'Per-metric sample counts are wrong -- see above.');
end
end

% ---------------------------------------------------------------------
function run_worker(workerId, nB, tbl, dbname)
% Worker 1 writes full batches (BER and recon_mse_r1, 1 frame each);
% worker 2 writes stage-limited batches (recon_mse_r1 only, 0 frames).
if ischar(workerId) || isstring(workerId), workerId = str2double(workerId); end
if ischar(nB) || isstring(nB), nB = str2double(nB); end
try, addMysqlJarOnce(); catch, end
conn = mysql_login(dbname);
params = struct('testcase', "metric_counts", 'point', 1);
for b = 1:nB
    if workerId == 1
        mysql_write(conn, tbl, params, 1, struct('BER',0.001,'recon_mse_r1',1.0), false);
    else
        mysql_write(conn, tbl, params, 0, struct('recon_mse_r1',3.0), false, [], [], struct('recon_mse_r1',1));
    end
end
end

function fresh_table(conn, tbl, ~)
try, execute(conn, "DROP TABLE IF EXISTS " + tbl); catch, end
% The pre-2026-10-16 schema: mysql_write must add metrics_n and write_seq.
execute(conn, "CREATE TABLE " + tbl + " (param_hash CHAR(64) PRIMARY KEY, parameters JSON, " + ...
    "metrics JSON, metrics_aux JSON NULL, frames_simulated INT NOT NULL)");
% Forget this session's "columns already added" cache for the table.
clear mysql_write
end

function [m, n, F, seq] = read_row(conn, tbl, ph)
T = mysql_load(conn, tbl, ph);
m = jsondecode(T.metrics{1});
n = metric_sample_count(T);
F = double(T.frames_simulated(1));
seq = NaN;
if ismember('write_seq', T.Properties.VariableNames), seq = double(T.write_seq(1)); end
end

function ok = chk(name, got, want)
got = double(got); ok = abs(got - want) < 1e-12 * max(1, abs(want));
if ok, s = 'PASS'; else, s = '*** FAIL ***'; end
fprintf('  %-28s got %-12.10g want %-12.10g %s\n', name, got, want, s);
end
