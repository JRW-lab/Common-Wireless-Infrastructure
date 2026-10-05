function print_progress_params(d)
% PRINT_PROGRESS_PARAMS  Console progress display, in the style of
% PVP-IPFM's Functions/updateProgressBar.m: clears the screen, lists every
% currently-active simulation parameter as "Display Name = value unit",
% then a text progress bar underneath.
%
% d is the raw progress-callback struct sim_head.m sends via its
% progress_fcn (a copy of the current point's `parameters` struct plus a
% handful of bookkeeping fields: profile_sel, num_iters, iter,
% primary_idx, config_idx, num_primary, num_configs, current_frames,
% num_frames). Those bookkeeping fields are used for the header/progress
% bar math below and excluded from the parameter listing itself - anything
% else in `d` IS a real simulation parameter and gets printed.
%
% Parameter display names/units come from param_display_info.m below,
% which is deliberately a lookup-with-fallback: any parameter NOT listed
% there still prints (using its raw field name, no unit) instead of
% breaking this display - add an entry there for a nicer name/unit as new
% parameters come up, rather than needing to touch this file.

meta_fields = {'profile_sel','num_iters','iter','primary_idx','config_idx', ...
               'num_primary','num_configs','current_frames','num_frames'};
params = d;
for i = 1:numel(meta_fields)
    if isfield(params, meta_fields{i})
        params = rmfield(params, meta_fields{i});
    end
end

config_count = (d.primary_idx - 1) * d.num_configs + d.config_idx;
config_length = d.num_primary * d.num_configs;
sim_count = config_count + (d.iter - 1) * d.num_primary * d.num_configs;
sim_length = d.num_iters * config_length;

clc;
fprintf("RUNNING PROFILE %d - CONFIG %d/%d - ITERATION %d/%d\n", ...
    d.profile_sel, config_count, config_length, d.iter, d.num_iters);
fprintf("\nCurrent settings:\n");
print_param_fields(params, '    ');

pct = 100 * sim_count / max(sim_length,1);
bar_len = 50;
filled_len = round(bar_len * sim_count / max(sim_length,1));
bar_str = [repmat('=',1,filled_len), repmat(' ',1,bar_len-filled_len)];
fprintf("\nProgress: [%s] %3.0f%% (frame %d/%d, sim %d/%d)\n\n", ...
    bar_str, pct, d.current_frames, d.num_frames, sim_count, sim_length);
end

function print_param_fields(params, indent)
fields = fieldnames(params);
for i = 1:numel(fields)
    name = fields{i};
    value = params.(name);
    [dispName,unit] = param_display_info(name);
    if isstruct(value) && isscalar(value)
        fprintf("%s%s:\n", indent, dispName);
        print_param_fields(value, [indent '    ']);
    else
        valStr = format_param_value(value);
        if strlength(unit) > 0
            fprintf("%s%s = %s %s\n", indent, dispName, valStr, unit);
        else
            fprintf("%s%s = %s\n", indent, dispName, valStr);
        end
    end
end
end

function valStr = format_param_value(value)
if islogical(value)
    valStr = string(mat2str(value));
elseif isstring(value) || ischar(value)
    valStr = string(value);
elseif isnumeric(value)
    if isscalar(value)
        valStr = string(value);
    else
        valStr = "[" + strjoin(string(value(:).'), ", ") + "]";
    end
else
    valStr = string(value);
end
end

function [dispName,unit] = param_display_info(fieldName)
% Flexible parameter-name/unit lookup - see this file's own header
% comment. Extend this table (never rmfield/remove entries other code
% might rely on) as new parameters are added elsewhere in the codebase.
table = struct( ...
    'system_name',       struct('name',"System",                        'unit',""), ...
    'receiver_name',     struct('name',"Receiver",                      'unit',""), ...
    'CP',                struct('name',"Cyclic Prefix",                 'unit',""), ...
    'T',                 struct('name',"Symbol Duration",               'unit',"s"), ...
    'N',                 struct('name',"Doppler Bins (N)",              'unit',""), ...
    'M',                 struct('name',"Delay Bins (M)",                'unit',""), ...
    'U',                 struct('name',"Oversampling (U)",              'unit',""), ...
    'Fc',                struct('name',"Carrier Frequency",             'unit',"Hz"), ...
    'vel',               struct('name',"Velocity",                      'unit',"km/hr"), ...
    'shape',             struct('name',"Pulse Shape",                   'unit',""), ...
    'alpha',             struct('name',"Roll-off Factor (alpha)",       'unit',""), ...
    'Q',                 struct('name',"Pulse Truncation (Q)",          'unit',""), ...
    'M_ary',             struct('name',"Modulation Order (M-ary)",      'unit',""), ...
    'EbN0',              struct('name',"Eb/N0",                         'unit',"dB"), ...
    'N_iters',           struct('name',"Equalizer Iterations",         'unit',""), ...
    'max_timing_offset', struct('name',"Max Timing Offset",             'unit',"xTs"), ...
    'csi_settings',      struct('name',"Channel Estimation Settings",   'unit',""), ...
    'method',            struct('name',"Method",                        'unit',""), ...
    'gamma_p',           struct('name',"Pilot SNR",                     'unit',"dB"), ...
    'PiTau',             struct('name',"Delay Grid Density (PiTau)",    'unit',""), ...
    'PiNu',              struct('name',"Doppler Grid Density (PiNu)",   'unit',""), ...
    'Pmax',              struct('name',"Max Model Order (Pmax)",        'unit',""), ...
    'NGS',               struct('name',"Gauss-Seidel Sweeps (NGS)",     'unit',"") ...
    );
if isfield(table, fieldName)
    dispName = table.(fieldName).name;
    unit = table.(fieldName).unit;
else
    dispName = string(fieldName);
    unit = "";
end
end
