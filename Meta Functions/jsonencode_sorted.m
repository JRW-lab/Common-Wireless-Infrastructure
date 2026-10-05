function [paramsJSON,paramHash] = jsonencode_sorted(parameters)
    % Recursively sort every struct's field names (not just the top
    % level) so that a nested-struct parameter (e.g. a csi_settings field
    % carrying its own sub-fields) hashes identically regardless of the
    % order those sub-fields happened to be constructed in - the same
    % stability guarantee this function has always given flat parameter
    % structs, extended to nested ones. A no-op for any struct that was
    % already flat, so existing hashes/accumulated data are unaffected.
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
