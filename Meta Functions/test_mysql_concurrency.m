function test_mysql_concurrency(varargin)
%TEST_MYSQL_CONCURRENCY  Regression test for mysql_write's lost-update race.
%
%   test_mysql_concurrency              run both scenarios (default)
%   test_mysql_concurrency('nBatches',N)  batches per worker (default 150)
%   test_mysql_concurrency('dbname',D)    database (default comm_database)
%
%   WHY THIS EXISTS AS A TEST AND NOT A NOTE. The bug it guards is
%   invisible in normal use: both workers complete, both report success,
%   nothing errors, nothing warns -- and a chunk of the frames is simply
%   not there. A rare silent corruption is worse than a frequent one,
%   because nobody goes looking for it. So the test forces the collision
%   instead of hoping for it: two real OS processes, deliberately the SAME
%   point, one frame per write, no pacing.
%
%   MEASURED ON THE PRE-FIX CODE (2026-10-05, 150 batches per worker):
%     steady-state  172 of 300 frames recorded -- 42.7% lost, silently.
%                   aux total_bits 1530 of 3000.
%     create-time   both workers INSERTed, the loser died on duplicate key
%                   and took all 150 of its frames with it.
%   Post-fix both scenarios are exact. If this test ever starts failing,
%   the compare-and-swap guard in mysql_write has been weakened -- do not
%   "fix" it by loosening the assertion.
%
%   The assertions are arithmetic and exact (frames_simulated must equal
%   the number of batches actually written, and the additive counters must
%   equal their known sums), so this is not a judgement call about whether
%   a number looks plausible.
%
%   Runs entirely against a scratch table that it creates and drops.
%   sim_lookup is never touched.
%
%   RUN IT FROM A PROJECT ROOT, not from this folder. mysql_login resolves
%   credentials relative to the working directory, so from inside the
%   submodule it finds no config and falls through to an interactive
%   prompt, which -batch cannot answer. From Common Wireless Simulator:
%     addpath('Meta Functions');
%     addpath('Common-Wireless-Infrastructure/Meta Functions');
%     test_mysql_concurrency

% ---- worker mode: re-entry from the spawned processes ----
if nargin >= 1 && isequal(varargin{1}, 'worker')
    run_worker(varargin{2:end});
    return
end

p = inputParser;
p.addParameter('nBatches', 150);
p.addParameter('dbname', 'comm_database');
p.parse(varargin{:});
nBatches = p.Results.nBatches;
dbname   = p.Results.dbname;

here = fileparts(mfilename('fullpath'));
try, addMysqlJarOnce(); catch, end
conn = mysql_login(dbname);

TBL = 'cas_test_tbl';
allok = true;

% Scenario 1 exercises the CREATE race (no row yet, both workers INSERT).
% Scenario 2 pre-seeds the row so both workers take the UPDATE path from
% their first batch -- without it the create race fires first and, on the
% pre-fix code, kills a worker outright, which MASKS whether the
% steady-state lost update is being exercised at all.
for precreate = [false true]
    if precreate
        fprintf('\n===== scenario 2: steady-state race (row pre-seeded) =====\n');
    else
        fprintf('\n===== scenario 1: create race (row absent) =====\n');
    end
    allok = run_scenario(conn, TBL, here, dbname, nBatches, precreate) && allok;
end

fprintf('\n%s\n', repmat('=', 1, 58));
if allok
    fprintf('TEST_MYSQL_CONCURRENCY: ALL PASS\n');
else
    error('test_mysql_concurrency:failed', ...
        'Concurrent accumulation is losing updates -- see the table above.');
end
end

% ---------------------------------------------------------------------
function ok = run_scenario(conn, TBL, here, dbname, nBatches, precreate)

try, execute(conn, "DROP TABLE IF EXISTS " + TBL); catch, end
execute(conn, "CREATE TABLE " + TBL + " (" + ...
    "param_hash VARCHAR(64) PRIMARY KEY, parameters JSON, metrics JSON, " + ...
    "metrics_aux JSON, frames_simulated INT)");

params = test_params();
[pj, ph] = jsonencode_sorted(params);
if precreate
    sm = jsonencode(struct('BER', 0));
    sa = jsonencode(struct('total_bit_errors',0,'total_bits',0,'total_frames',0));
    execute(conn, sprintf(...
        "INSERT INTO %s (param_hash,parameters,metrics,metrics_aux,frames_simulated) VALUES ('%s','%s','%s','%s',0)", ...
        TBL, ph, pj, sm, sa));
end

fprintf('2 workers x %d batches x 1 frame, same point\n', nBatches);
mk = @(id) sprintf(['matlab -batch "addpath(''%s''); ' ...
    'test_mysql_concurrency(''worker'',%d,%d,''%s'',''%s'')"'], ...
    here, id, nBatches, TBL, dbname);
j1 = java.lang.ProcessBuilder({'cmd','/c', mk(1)}).redirectErrorStream(true).start();
j2 = java.lang.ProcessBuilder({'cmd','/c', mk(2)}).redirectErrorStream(true).start();
j1.waitFor(); j2.waitFor();
e1 = j1.exitValue(); e2 = j2.exitValue();
fprintf('worker exits: %d, %d\n', e1, e2);
if e1 ~= 0 || e2 ~= 0
    dump(j1,'W1'); dump(j2,'W2');
end

T = fetch(conn, "SELECT * FROM " + TBL);
ok = true;
if isempty(T)
    fprintf('*** FAIL *** no row was written at all\n');
    ok = false;
else
    aux = jsondecode(T.metrics_aux{1});
    ok = chk('frames_simulated',   double(T.frames_simulated(1)), 2*nBatches) && ok;
    ok = chk('aux total_bits',     aux.total_bits,                20*nBatches) && ok;
    ok = chk('aux total_bit_errs', aux.total_bit_errors,          3*nBatches) && ok;
    ok = chk('worker exit codes',  double(e1 == 0 && e2 == 0),    1) && ok;
end
try, execute(conn, "DROP TABLE " + TBL); catch, end
end

% ---------------------------------------------------------------------
function run_worker(workerId, nBatches, tableName, dbname)
% Emulates sim_save's caller pattern exactly: read the row, merge this
% batch into what was found, hand mysql_write BOTH the cumulative and the
% per-batch delta.
if ischar(workerId) || isstring(workerId), workerId = str2double(workerId); end
if ischar(nBatches) || isstring(nBatches), nBatches = str2double(nBatches); end
try, addMysqlJarOnce(); catch, end
conn = mysql_login(dbname);
params = test_params();
[~, h] = jsonencode_sorted(params);
for b = 1:nBatches
    metrics_add = struct('BER', 0.001 * workerId);
    new_aux = struct('total_bit_errors', workerId, 'total_bits', 10, ...
                     'total_frames', 1);
    T = mysql_load(conn, tableName, h);
    old_aux = [];
    if ~isempty(T) && ismember('metrics_aux', T.Properties.VariableNames) ...
            && ~ismissing(T.metrics_aux(1)) && ~isempty(T.metrics_aux{1})
        old_aux = jsondecode(T.metrics_aux{1});
    end
    cum = merge_metrics_aux(old_aux, new_aux);
    mysql_write(conn, tableName, params, 1, metrics_add, false, cum, new_aux);
end
fprintf('worker %d wrote %d batches\n', workerId, nBatches);
end

% ---------------------------------------------------------------------
function p = test_params()
p = struct('testcase', "cas_concurrency", 'point', 1);
end

function ok = chk(name, got, want)
got = double(got); ok = abs(got - want) < 1e-9;
if ok, s = 'PASS'; else, s = '*** FAIL ***'; end
fprintf('  %-20s got %-8g want %-8g %s\n', name, got, want, s);
if ~ok && want > 0 && got < want
    fprintf('  %-20s lost %g of %g (%.1f%%)\n', '', want-got, want, ...
        100*(want-got)/want);
end
end

function dump(j, tag)
try
    is = j.getInputStream(); n = is.available();
    if n <= 0, return; end
    b = zeros(1, n, 'int8');
    for k = 1:n, b(k) = is.read(); end
    for ln = splitlines(string(char(typecast(b, 'uint8'))))'
        if strlength(strtrim(ln)) > 0
            fprintf('  [%s] %s\n', tag, strtrim(ln));
        end
    end
catch
end
end
