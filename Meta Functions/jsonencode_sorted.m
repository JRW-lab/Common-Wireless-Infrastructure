function [paramsJSON,paramHash] = jsonencode_sorted(parameters)
    % FLATTEN, then sort, then hash (2026-10-12).
    %
    % If the project on the path defines flatten_params, the parameters are
    % first reduced to a single-level struct by it, so that a setting has
    % ONE name in the key no matter which sub-structure a profile put it
    % in. Before this, top-level Pmax and csi_settings.Pmax -- read
    % identically by the simulator -- produced different param_hashes, and
    % every such pair was a duplicate datum. Doing it HERE, the one function
    % every hash site already calls, means no caller can forget it.
    %
    % A project without flatten_params keeps the old behaviour exactly.
    % flatten_params is the identity on an already-flat struct, so rows that
    % never nested anything keep their existing hash either way.
    %
    % The JSON returned is the FLAT form, so the parameters stored next to a
    % row are exactly what its key was computed from.
    if exist('flatten_params', 'file') == 2
        parameters = flatten_params(parameters);
    end

    % Recursively sort every struct's field names (not just the top
    % level) so that a nested-struct parameter hashes identically
    % regardless of the order its sub-fields were constructed in. After
    % flattening there is nothing nested left in a project that flattens,
    % but the recursion still serves projects that do not.
    sortedStruct = sort_struct_fields_recursive(parameters);

    % Encode to JSON
    paramsJSON = jsonencode(sortedStruct);

    % Get data hash
    paramHash = DataHash(paramsJSON,'SHA-256');

end

function out = sort_struct_fields_recursive(s)
    if ~isstruct(s)
        out = s;
        return;
    end
    if numel(s) ~= 1
        out = s;
        for i = 1:numel(s)
            out(i) = sort_struct_fields_recursive(s(i));
        end
        return;
    end
    fields = sort(fieldnames(s));
    out = struct();
    for i = 1:numel(fields)
        out.(fields{i}) = sort_struct_fields_recursive(s.(fields{i}));
    end
end
