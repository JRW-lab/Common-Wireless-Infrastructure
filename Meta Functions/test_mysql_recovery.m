function test_mysql_recovery(dbname)
% TEST_MYSQL_RECOVERY Regression test for connection-loss recovery.
%
%   test_mysql_recovery
%   test_mysql_recovery(dbname)
%
%   Guards the failure that killed an overnight collection on 2026-10-07:
%   mysql_load's self-heal closes the connection before reconnecting, so a
%   failed reconnect leaves the caller holding a deleted handle, and the
%   old recovery idiom then read conn.DataSource off it and threw
%   "Invalid or deleted object." - masking the real event, a dropped
%   connection, and ending the run.
%
%   Gates 1 to 4 run against the live server. Gates 5 and 6 shadow
%   mysql_ensure_conn with a stub written to a temporary folder, so the
%   retry loop is exercised without taking the server down.
%
%   Nothing is written to sim_lookup.
%
%   INPUTS:
%     dbname: database to connect to, default comm_database

% Function setup
if nargin < 1 || isempty(dbname), dbname = 'comm_database'; end
addMysqlJarOnce();
tbl  = 'sim_lookup';
hl   = {'0000000000000000000000000000000000000000000000000000000000000000'};
g    = false(1,6);

% Gate 1: an unbroken connection behaves exactly as mysql_load does
conn  = mysql_login(dbname);
Tref  = mysql_load(conn, tbl, hl);
[T1, conn, ok1] = mysql_load_resilient(conn, dbname, tbl, hl, table);
g(1) = ok1 && height(T1) == height(Tref);
report(1, g(1), sprintf('ok=%d rows %d vs %d', ok1, height(T1), height(Tref)));

% Gate 2: the reported crash - a deleted handle is replaced, not read
conn = mysql_login(dbname);
close(conn);
oldIdiomThrew = false;
try
    dsUnused = conn.DataSource; %#ok<NASGU>
catch
    oldIdiomThrew = true;
end
[~, conn, ok2] = mysql_load_resilient(conn, dbname, tbl, hl, table);
g(2) = ok2 && oldIdiomThrew;
report(2, g(2), sprintf('old idiom threw=%d, recovered=%d', oldIdiomThrew, ok2));

% Gate 3: the deleted handle is also the one mysql_login cached
conn = mysql_login(dbname);
close(conn);
c3   = mysql_login(dbname);
g(3) = isopen(c3);
report(3, g(3), sprintf('reconnected isopen=%d', g(3)));

% Gate 4: permanent failures stop, transient ones keep waiting
cases = { 'Access denied for user', true
          'MySQL is not configured for this project', true
          'Communications link failure', false
          'The last packet successfully received from the server', false
          'Connection refused: connect', false };
g(4) = true;
for i = 1:size(cases,1)
    got  = mysql_is_permanent_failure(MException('test:case','%s',cases{i,1}));
    g(4) = g(4) && (got == cases{i,2});
end
report(4, g(4), sprintf('%d classifications', size(cases,1)));

% Build the stub used by gates 5 and 6
stubDir = fullfile(tempdir, 'test_mysql_recovery_stub');
if ~exist(stubDir, 'dir'), mkdir(stubDir); end
writeStub(stubDir);
addpath(stubDir, '-begin');
cleanup = onCleanup(@() cleanupStub(stubDir));
global STUB_FAILS STUB_CALLS STUB_MSG %#ok<GVMIS>
Tprev = table(99, 'VariableNames', {'frames_simulated'});

% Gate 5: an outage is waited out, with backoff, and then recovers
STUB_FAILS = 3; STUB_CALLS = 0; STUB_MSG = 'Communications link failure';
[T5, ~, ok5] = mysql_load_resilient([], "db", "t", {}, Tprev);
g(5) = ok5 && STUB_CALLS == 4 && height(T5) == 3;
report(5, g(5), sprintf('ok=%d after %d attempts', ok5, STUB_CALLS));

% Gate 6: an exhausted budget returns the previous table instead of throwing
STUB_FAILS = 1e9; STUB_CALLS = 0;
[T6, ~, ok6] = mysql_load_resilient([], "db", "t", {}, Tprev, 12);
g(6) = ~ok6 && height(T6) == 1 && T6.frames_simulated(1) == 99;
report(6, g(6), sprintf('ok=%d, previous table returned=%d', ok6, height(T6) == 1));

% Report
if all(g)
    fprintf('test_mysql_recovery: all %d gates PASS\n', numel(g));
else
    error('test_mysql_recovery:failed', 'Gates failed: %s', mat2str(find(~g)));
end

end

function report(n, ok, detail)

% Print one gate result
if ok, verdict = 'PASS'; else, verdict = 'FAIL'; end
fprintf('  gate %d %s  %s\n', n, verdict, detail);

end

function writeStub(stubDir)

% Stub mysql_ensure_conn: fail STUB_FAILS times, then succeed
fid = fopen(fullfile(stubDir, 'mysql_ensure_conn.m'), 'w');
fprintf(fid, 'function conn = mysql_ensure_conn(conn, dbname) %%#ok<INUSD>\n');
fprintf(fid, 'global STUB_FAILS STUB_CALLS STUB_MSG\n');
fprintf(fid, 'STUB_CALLS = STUB_CALLS + 1;\n');
fprintf(fid, 'if STUB_CALLS <= STUB_FAILS, error(''stub:down'', ''%%s'', STUB_MSG); end\n');
fprintf(fid, 'conn = ''LIVE'';\n');
fprintf(fid, 'end\n');
fclose(fid);

% Stub mysql_load: return a known three-row table
fid = fopen(fullfile(stubDir, 'mysql_load.m'), 'w');
fprintf(fid, 'function T = mysql_load(conn, table_name, hash_list) %%#ok<INUSD>\n');
fprintf(fid, 'T = table((1:3)'', ''VariableNames'', {''frames_simulated''});\n');
fprintf(fid, 'end\n');
fclose(fid);

end

function cleanupStub(stubDir)

% Remove the stub from the path and disk
warning('off', 'MATLAB:rmpath:DirNotFound');
rmpath(stubDir);
if exist(stubDir, 'dir'), rmdir(stubDir, 's'); end

end
