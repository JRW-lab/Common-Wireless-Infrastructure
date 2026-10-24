function n_deleted = delete_merged(conn, dbname, table_name, paramHash)
% DELETE_MERGED  Delete one simulation point from every results source.
%
%   n_deleted = delete_merged(conn, dbname, table_name, paramHash)
%
%   Readers merge a point's rows across all registered sources (load_merged),
%   so deleting it from the caller's own database alone would leave the
%   other machines' frames in every figure. This deletes the point from each
%   source in db_sources. It first checks every source for the point, and
%   deletes nothing unless all of them answered and none of the holders is a
%   frozen table, so a deletion is never left half done.
%
%   Storage step 7b (notes/STORAGE_BACKENDS_PLAN.md):
%     - each store deletes with its adapter's delete_point, which removes
%       the row and RETIRES the point's ledger records to an archive in the
%       same transaction (user decision 2026-10-22), so deleted frames no
%       longer count toward ledger_frames or paired_target;
%     - this computer's primary may be SQLite or text (conn its handle,
%       dbname ""), and its mirrors (not Excel, not stale) lose the point
%       too; a mirror that fails is marked stale;
%     - another computer is deleted from only when all its stores are
%       MySQL. One that holds the point in a file store refuses the whole
%       deletion (delete_merged:remoteFileStore): only its owner writes its
%       files, so delete it there.
%
%   INPUTS:
%     conn:       the caller's handle to its own primary store
%     dbname:     the caller's database name ("" for a file primary)
%     table_name: its results table
%     paramHash:  the point to delete
%
%   OUTPUT:
%     n_deleted: number of sources the point was deleted from.
%
%   LIMITS: a source that is switched off blocks the deletion with an error;
%   delete when every machine holding frames is reachable. Another
%   computer's file stores are judged from their synced copies, which can
%   lag. Notes: load_merged_NOTES.md S3.

% Check every source for the point (another computer's files through their synced copies)
src = db_sources(dbname, table_name);
cs = cell(1, numel(src));
holds = false(1, numel(src));
for k = 1:numel(src)
    [holds(k), cs{k}] = holds_point(src(k), conn, paramHash);
end

% A frozen table cannot lose rows, so the point could not be fully deleted
frozen = holds & [src.role] == "legacy-frozen";
if any(frozen)
    error('delete_merged:frozen', ['Point %s has frames in the frozen table "%s"; nothing was deleted. ' ...
        'Unfreeze it, or delete by hand.'], paramHash, strjoin([src(frozen).name], ', '));
end

% Another computer's files are written only by that computer
remote_file = false(1, numel(src));
for k = find(holds & ~[src.own])
    remote_file(k) = ~isempty(src(k).stores) && any([src(k).stores.kind] ~= "mysql");
end
if any(remote_file)
    error('delete_merged:remoteFileStore', ['Point %s is held by %s, which keeps results in files only it may write; ' ...
        'nothing was deleted. Delete it on that computer.'], paramHash, strjoin([src(remote_file).writer], ', '));
end

% Delete from every holder; this computer's mirrors follow its primary
for k = find(holds)
    kind = "mysql";
    if src(k).own && ~isempty(src(k).stores), kind = src(k).stores(1).kind; end
    ad = store_adapter(kind);
    ad.delete_point(cs{k}, src(k).table, paramHash);
    if src(k).own, delete_from_mirrors(src(k).table, paramHash); end
end
n_deleted = nnz(holds);
end

function [tf, c] = holds_point(s, conn, h)
% Whether one source holds point h, and the handle to delete it with.
c = [];
if s.own
    c = conn;
    if ~isempty(s.stores) && s.stores(1).kind ~= "mysql"
        tf = height(store_read(s, h, "own")) > 0;
        return
    end
elseif ~isempty(s.stores) && any([s.stores.kind] ~= "mysql")
    tf = height(store_read(s, h)) > 0;
    return
else
    c = db_source_conn(s);
end
r = fetch(c, sprintf("SELECT COUNT(*) AS n FROM %s WHERE param_hash = '%s'", s.table, h));
tf = double(r.n(1)) > 0;
end

function delete_from_mirrors(table_name, h)
% This computer's mirrors lose the point too, chosen by results_write's rule: only for the primary's own table, not Excel
% (the next flush rewrites it), not stale ones (resync rebuilds them).
writer = host_id();
reg = db_registry();
if isempty(reg), return; end
e = find([reg.role] == "machine" & [reg.writer] == writer, 1);
if isempty(e), return; end
st = machine_stores(reg(e));
if numel(st) < 2 || string(table_name) ~= st(1).table, return; end
S = store_status(writer);
for j = 2:numel(st)
    key = store_key(st(j));
    i = find(strcmp({S.key}, key), 1);
    if st(j).kind == "excel" || (~isempty(i) && S(i).stale), continue; end
    try
        am = store_adapter(st(j).kind);
        cm = am.open(st(j));
        am.delete_point(cm, st(j).table, h);
        if st(j).kind == "sqlite", close(cm); end
    catch ME
        store_status(writer, key, struct('stale', true, 'reason', "delete failed: " + string(ME.message), 'first_uid', "", ...
            'time', string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'))));
        warning('storage:mirrorStale', 'Mirror %s marked stale (delete of %s failed: %s).', key, h, ME.message);
    end
end
end
