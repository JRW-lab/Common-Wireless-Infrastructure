function [R, L] = store_dump(P)
% STORE_DUMP  Every row and every ledger record of one of this computer's stores.
%
%   [R, L] = store_dump(P)
%
%   Used to rebuild a mirror (store_resync) and to export the Excel mirror
%   (store_flush), storage steps 5 and 7a of notes/STORAGE_BACKENDS_PLAN.md.
%
%   INPUT:
%     P: a machine_stores element of this computer (usually the primary)
%
%   OUTPUTS:
%     R: rows, columns param_hash, parameters, metrics, metrics_n,
%        metrics_aux, frames_simulated
%     L: ledger, one row per batch, ordered by batch_id when the store has
%        one. MySQL and SQLite give every ledger column (absent lane,
%        seed_base or k_start as NaN). A text store gives param_hash,
%        n_frames, batch_uid, lane, seed_base and k_start only: its log
%        holds the batch, not a separate delta record.
%
%   LIMITS: read only; reads the live file of a SQLite or text store.

% MySQL: the table and its ledger (none yet is an empty ledger)
switch P.kind
    case "mysql"
        cp = mysql_login(P.dbname);
        R = fetch(cp, "SELECT param_hash, parameters, metrics, metrics_n, metrics_aux, frames_simulated FROM " + P.table);
        lt = P.table + "_batches"; if P.table == "sim_lookup", lt = "sim_batches"; end
        try
            L = fetch(cp, "SELECT * FROM " + lt + " ORDER BY batch_id");
        catch ME
            if ~contains(ME.message, "doesn't exist"), rethrow(ME); end
            L = table();
        end

    % SQLite: MATLAB sqlite can't fetch NULLs, so nullable columns come through COALESCE and go back to NaN or ''
    case "sqlite"
        ap = store_adapter("sqlite");
        cp = ap.open(P);
        try
            R = ap.load_rows(cp);
            L = fetch(cp, "SELECT batch_id, param_hash, machine, COALESCE(lane,-1) AS lane, COALESCE(seed_base,-1) AS seed_base, " + ...
                "COALESCE(k_start,-1) AS k_start, n_frames, batch_uid, COALESCE(code_rev,'') AS code_rev, " + ...
                "COALESCE(matlab_release,'') AS matlab_release, COALESCE(started_at,'') AS started_at, " + ...
                "COALESCE(finished_at,'') AS finished_at, delta FROM sim_batches ORDER BY batch_id");
        catch ME
            close(cp); rethrow(ME);
        end
        close(cp);
        for f = ["lane" "seed_base" "k_start"]
            v = double(L.(f)); v(v < 0) = NaN; L.(f) = v;
        end

    % Text: rows rebuilt from the log, and the uid index as the ledger
    case "text"
        ap = store_adapter("text");
        cp = ap.open(P);
        R = ap.load_rows(cp);
        L = ap.ledger_rows(cp);

    otherwise
        error('storage:kindNotBuilt', 'store_dump can not read a "%s" store.', P.kind);
end
end
