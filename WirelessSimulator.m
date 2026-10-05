classdef WirelessSimulator < matlab.apps.AppBase
    % WirelessSimulator Unified GUI for all wireless communication projects.
    % Builds an app_settings struct and passes it to sim_head().
    %
    % Works with any project that implements saved_profiles() and sim_head(app_settings).

    % Every project now writes to this one merged results table (server-side
    % consolidation of the old per-project results_twc/results_music/
    % otfs_journal/sim_results tables) - it's fixed, not a GUI option.
    properties (Constant, Access = private)
        ResultsTableName = 'sim_lookup'
    end

    % Internal state (not UI components)
    properties (Access = private)
        AllProfiles     cell = {}
        AllProfileNames cell = {}
    end

    % UI Components
    properties (Access = public)
        UIFigure                         matlab.ui.Figure

        % Sidebar
        SidebarPanel                     matlab.ui.container.Panel
        ProfileHeaderLabel               matlab.ui.control.Label
        ProfileSearchField               matlab.ui.control.EditField
        ProfileListBox                   matlab.ui.control.ListBox
        ReloadProfilesButton             matlab.ui.control.Button

        % Content header
        ProfileTitleLabel                matlab.ui.control.Label
        ProfileSubtitleLabel             matlab.ui.control.Label
        ProfileDetailsButton             matlab.ui.control.Button
        FrameCountsButton                matlab.ui.control.Button

        % Run card
        RunPanel                         matlab.ui.container.Panel
        NumberofTrialsEditField          matlab.ui.control.NumericEditField
        NumberofTrialsEditFieldLabel     matlab.ui.control.Label
        TrialsPerIterationEditField      matlab.ui.control.NumericEditField
        TrialsPerIterationEditFieldLabel matlab.ui.control.Label
        ParallelizationCheckBox          matlab.ui.control.CheckBox
        IgnoreErrorsCheckBox             matlab.ui.control.CheckBox
        IterativelyRenderCheckBox        matlab.ui.control.CheckBox
        DeleteSelectedConfigsCheckBox    matlab.ui.control.CheckBox

        % Storage card
        StoragePanel                     matlab.ui.container.Panel
        SavePriorityDropDown             matlab.ui.control.DropDown
        SavePriorityDropDownLabel        matlab.ui.control.Label
        EnableMySQLCheckBox              matlab.ui.control.CheckBox
        SaveExcelCheckBox                matlab.ui.control.CheckBox
        ResultsTableCaptionLabel         matlab.ui.control.Label
        ResultsTableValueLabel           matlab.ui.control.Label

        % Adaptive stopping card
        ConvergencePanel                 matlab.ui.container.Panel
        EnableAdaptiveCheckBox           matlab.ui.control.CheckBox
        ToleranceEditField               matlab.ui.control.NumericEditField
        ToleranceEditFieldLabel          matlab.ui.control.Label
        MinFramesEditField               matlab.ui.control.NumericEditField
        MinFramesEditFieldLabel          matlab.ui.control.Label
        ConfidenceDropDown               matlab.ui.control.DropDown
        ConfidenceDropDownLabel          matlab.ui.control.Label

        % Output card
        OutputPanel                      matlab.ui.container.Panel
        FigureStatisticDropDown          matlab.ui.control.DropDown
        FigureStatisticDropDownLabel     matlab.ui.control.Label

        % Status strip + actions
        ProgressTrackPanel               matlab.ui.container.Panel
        ProgressFillPanel                matlab.ui.container.Panel
        StatusLine1Label                 matlab.ui.control.Label
        StatusLine2Label                 matlab.ui.control.Label
        SimulateButton                   matlab.ui.control.Button
        GenerateFigureButton             matlab.ui.control.Button
    end

    % Callbacks
    methods (Access = private)

        function startupFcn(app)
            refreshProfiles(app);
            setStatus(app, "Ready.", false);
        end

        %% Profile list: population, filtering, subtitle text

        function refreshProfiles(app)
            [profiles, names] = saved_profiles();
            % saved_profiles() may return profile_names as either a cell
            % array of char/string or a string array depending on project;
            % normalize to cellstr so {i} indexing works everywhere below.
            if ~iscell(names)
                names = cellstr(names);
            end
            app.AllProfiles = profiles;
            app.AllProfileNames = names;
            applyProfileFilter(app, '');
        end

        function applyProfileFilter(app, filterText)
            names = app.AllProfileNames;
            idx = 1:numel(names);
            if ~isempty(filterText)
                mask = contains(lower(string(names)), lower(string(filterText)));
                idx = idx(mask);
            end
            items = cell(1, numel(idx));
            for k = 1:numel(idx)
                i = idx(k);
                % PREFIX IS `i`, THE INDEX INTO all_profiles -- NOT `k`, the
                % row's position in the filtered list. With a filter active
                % the two differ, and a number that renumbers itself as you
                % type in the search box would be worse than no number at
                % all: the /render-figure skill takes this index as its only
                % argument, so it has to mean the same thing in every view.
                items{k} = sprintf('%d. %s\n%s', i, names{i}, ...
                    profileSubtitle(app, app.AllProfiles{i}));
            end
            prevValue = app.ProfileListBox.Value;
            app.ProfileListBox.Items = items;
            app.ProfileListBox.ItemsData = num2cell(idx);
            if ~isempty(idx) && ismember(prevValue, idx)
                app.ProfileListBox.Value = prevValue;
            elseif ~isempty(idx)
                app.ProfileListBox.Value = idx(1);
            end
            updateProfileHeader(app);
        end

        function txt = profileSubtitle(~, p)
            n = 0;
            if isfield(p, 'configs')
                n = numel(p.configs);
            end
            if n == 1
                configWord = "1 config";
            else
                configWord = sprintf("%d configs", n);
            end
            valStr = formatValueList(p.primary_vals);
            txt = sprintf('%s sweep: %s - %s', p.primary_var, valStr, configWord);
        end

        function updateProfileHeader(app)
            idx = app.ProfileListBox.Value;
            if isempty(idx) || idx < 1 || idx > numel(app.AllProfiles)
                app.ProfileTitleLabel.Text = 'No matching profiles';
                app.ProfileSubtitleLabel.Text = '';
                return;
            end
            app.ProfileTitleLabel.Text = app.AllProfileNames{idx};
            app.ProfileSubtitleLabel.Text = profileSubtitle(app, app.AllProfiles{idx});
        end

        function ProfileSearchFieldValueChanging(app, event)
            applyProfileFilter(app, event.Value);
        end

        function ProfileListBoxValueChanged(app, ~)
            updateProfileHeader(app);
        end

        function ReloadProfilesButtonPushed(app, ~)
            refreshProfiles(app);
            setStatus(app, "Profiles reloaded.", false);
        end

        function ProfileDetailsButtonPushed(app, ~)
            idx = app.ProfileListBox.Value;
            if isempty(idx) || idx < 1 || idx > numel(app.AllProfiles)
                return;
            end
            name = app.AllProfileNames{idx};
            profile = app.AllProfiles{idx};
            try
                bodyText = jsonencode(profile, 'PrettyPrint', true);
            catch
                bodyText = evalc('disp(profile)');
            end

            detailFig = uifigure('Name', "Profile Details - " + name);
            detailFig.Position = [200 120 620 600];

            titleLabel = uilabel(detailFig);
            titleLabel.Position = [16 560 588 24];
            titleLabel.FontWeight = 'bold';
            titleLabel.FontSize = 14;
            titleLabel.Text = name;

            detailArea = uitextarea(detailFig);
            detailArea.Position = [16 16 588 534];
            detailArea.Editable = 'off';
            detailArea.FontName = 'Consolas';
            detailArea.Value = cellstr(splitlines(string(bodyText)));
        end

        function FrameCountsButtonPushed(app, ~)
            % Show how many frames are actually accumulated for every test
            % point of the selected profile: one ROW per primary-variable
            % value, one COLUMN per config. Read-only -- queries the results
            % table and writes nothing.
            idx = app.ProfileListBox.Value;
            if isempty(idx) || idx < 1 || idx > numel(app.AllProfiles)
                return;
            end
            name = app.AllProfileNames{idx};
            profile = app.AllProfiles{idx};

            % The GUI is launched via launch_gui.m, which only adds the
            % infrastructure folder to the path -- jsonencode_sorted and
            % mysql_load live in its "Meta Functions" subfolder, and the
            % project may have its own. Add both defensively so this button
            % works without having run a simulation first (which is what
            % normally calls sim_head and sets up the full path).
            infraDir = fileparts(mfilename('fullpath'));
            projRoot = fileparts(infraDir);
            addpath(fullfile(infraDir, 'Meta Functions'));
            if isfolder(fullfile(projRoot, 'Meta Functions'))
                addpath(fullfile(projRoot, 'Meta Functions'));
            end

            primary_var  = profile.primary_var;
            primary_vals = profile.primary_vals;
            configs      = profile.configs;
            nP = numel(primary_vals);
            nC = numel(configs);

            % FLAT CONFIGS (2026-09-21): a config measured once, at
            % profile.flat_anchor, and drawn as a horizontal line (see
            % sim_head.m's FLAT CONFIGS note). Only its anchor row is a real
            % test point; the rest of its column is shown as NaN ("-")
            % rather than 0, because 0 here means "a point that needs
            % collecting and has none", which is exactly what these are not.
            flat_cols = [];
            flat_anchor_row = [];
            if isfield(profile,'flat_configs') && ~isempty(profile.flat_configs)
                flat_cols = unique(profile.flat_configs(:)).';
                if isfield(profile,'flat_anchor') && ~isempty(profile.flat_anchor)
                    flat_anchor_row = find(primary_vals == profile.flat_anchor, 1);
                end
                if isempty(flat_anchor_row)
                    flat_anchor_row = 1;
                end
            end
            is_point = true(nP, nC);
            if ~isempty(flat_cols)
                is_point(:, flat_cols) = false;
                is_point(flat_anchor_row, flat_cols) = true;
            end

            % Column headers: prefer the profile's own legend text, since
            % that is what the reader sees on the rendered figure. Fall back
            % to the config's own overridden fields when a profile has no
            % legend (or a mismatched count -- do not assume they line up).
            colNames = cell(1,nC);
            haveLegend = isfield(profile,'legend_vec') && numel(profile.legend_vec) == nC;
            for c = 1:nC
                if haveLegend
                    colNames{c} = char(string(profile.legend_vec{c}));
                else
                    fn = fieldnames(configs{c});
                    parts = strings(1,numel(fn));
                    for k = 1:numel(fn)
                        v = configs{c}.(fn{k});
                        if isnumeric(v) && isscalar(v)
                            parts(k) = fn{k} + "=" + string(v);
                        else
                            parts(k) = string(fn{k});
                        end
                    end
                    colNames{c} = char(strjoin(parts, ", "));
                end
            end

            rowNames = cell(nP,1);
            for r = 1:nP
                rowNames{r} = char(string(primary_var) + "=" + string(primary_vals(r)));
            end

            % --- query the results table ---
            counts = nan(nP,nC);
            errMsg = '';
            try
                conn = mysql_login("comm_database");
                cleanupConn = onCleanup(@() close(conn));
                hashes = cell(nP,nC);
                for c = 1:nC
                    for r = 1:nP
                        parameters = profile.default_parameters;
                        parameters.(primary_var) = primary_vals(r);
                        ov = configs{c};
                        fn = fieldnames(ov);
                        for k = 1:numel(fn)
                            parameters.(fn{k}) = ov.(fn{k});
                        end
                        % Mirror sim_head.m's own ODDM scrubbing, or the
                        % hashes will not match what was actually written.
                        if isfield(parameters,'system_name') && parameters.system_name == "ODDM" ...
                                && isfield(parameters,'U')
                            parameters = rmfield(parameters,'U');
                        end
                        [~, h] = jsonencode_sorted(parameters);
                        hashes{r,c} = h;
                    end
                end
                T = mysql_load(conn, app.ResultsTableName, hashes(:));
                if ~isempty(T)
                    allH = string(T.param_hash);
                    for c = 1:nC
                        for r = 1:nP
                            if ~is_point(r,c)
                                counts(r,c) = NaN;   % not a test point
                                continue;
                            end
                            k = find(allH == hashes{r,c}, 1);
                            if isempty(k)
                                counts(r,c) = 0;
                            else
                                counts(r,c) = T.frames_simulated(k);
                            end
                        end
                    end
                else
                    counts(:) = 0;
                    counts(~is_point) = NaN;
                end
            catch ME
                errMsg = ME.message;
            end

            % --- window ---
            f = uifigure('Name', "Frame Counts - " + name);
            f.Position = [220 140 min(1100, 260 + 130*nC) 520];

            hdr = uilabel(f);
            hdr.Position = [16 480 f.Position(3)-32 24];
            hdr.FontWeight = 'bold';
            hdr.FontSize = 14;
            hdr.Text = char(name);

            sub = uilabel(f);
            sub.Position = [16 458 f.Position(3)-32 20];
            if isempty(errMsg)
                tot = sum(counts(~isnan(counts)));
                nzero = sum(counts(is_point) == 0);
                mn = min(counts(is_point));
                if isempty(mn), mn = 0; end
                % A flat config has an anchor ONLY in the flat_anchor form.
                % In the flat_defaults form the primary variable is absent
                % from its parameter struct altogether, so there is no
                % anchor value to name -- reading profile.flat_anchor there
                % throws "Unrecognized field name". The row-index logic
                % above already handles both forms; this label has to as
                % well.
                flatTxt = '';
                if ~isempty(flat_cols)
                    if isfield(profile,'flat_anchor') && ~isempty(profile.flat_anchor)
                        flatTxt = sprintf('   |   %d flat config(s), measured once at %s=%g', ...
                            numel(flat_cols), char(string(primary_var)), profile.flat_anchor);
                    else
                        flatTxt = sprintf(['   |   %d flat config(s), measured once ' ...
                            '(independent of %s)'], ...
                            numel(flat_cols), char(string(primary_var)));
                    end
                end
                sub.Text = sprintf(['table "%s"   |   %d points   |   total %s frames   |   ' ...
                    'min %s   |   %d point(s) with no data%s'], ...
                    char(app.ResultsTableName), nnz(is_point), ...
                    char(string(tot)), char(string(mn)), nzero, flatTxt);
            else
                sub.FontColor = [0.72 0.11 0.11];
                sub.Text = ['Could not read the results table: ' errMsg];
            end

            t = uitable(f);
            t.Position = [16 16 f.Position(3)-32 434];
            t.Data = counts;
            t.RowName = rowNames;
            t.ColumnName = colNames;
            t.ColumnWidth = repmat({'fit'}, 1, nC);

            % Highlight points with nothing collected yet, so gaps are
            % obvious at a glance rather than needing to be read for.
            % Cells of a flat config that are not its anchor are greyed
            % instead -- they are NOT gaps to be filled.
            try
                s = uistyle('BackgroundColor', [1 0.92 0.92]);
                [rz, cz] = find(counts == 0 & is_point);
                if ~isempty(rz)
                    addStyle(t, s, 'cell', [rz cz]);
                end
                sflat = uistyle('BackgroundColor', [0.94 0.94 0.94]);
                [rf, cf] = find(~is_point);
                if ~isempty(rf)
                    addStyle(t, sflat, 'cell', [rf cf]);
                end
            catch
                % uistyle/addStyle unavailable on older releases - the table
                % is still perfectly usable without the highlighting.
            end
        end

        %% Error reporting

        function showErrorDialog(app, ME)
            % Full, copyable error report (message + identifier + full
            % stack trace with file/line numbers) - reuses the same
            % uifigure+uitextarea pattern as ProfileDetailsButtonPushed's
            % detail viewer, since uitextarea content (unlike a uilabel's)
            % can actually be selected and copied. Also printed to the
            % Command Window so it's captured even if this dialog is
            % closed or missed.
            report = getReport(ME, 'extended', 'hyperlinks', 'off');
            disp("===== Simulation error =====");
            disp(report);
            disp("=============================");

            detailFig = uifigure('Name', 'Simulation Error');
            detailFig.Position = [200 100 760 560];

            titleText = "Error";
            if ~isempty(ME.identifier)
                titleText = "Error: " + string(ME.identifier);
            end
            titleLabel = uilabel(detailFig);
            titleLabel.Position = [16 520 728 24];
            titleLabel.FontWeight = 'bold';
            titleLabel.FontSize = 14;
            titleLabel.FontColor = [0.72 0.11 0.11];
            titleLabel.Text = titleText;

            hintLabel = uilabel(detailFig);
            hintLabel.Position = [16 496 728 20];
            hintLabel.FontColor = [0.35 0.35 0.35];
            hintLabel.Text = 'Full report below (click, Ctrl+A, Ctrl+C to copy) - also printed to the Command Window.';

            detailArea = uitextarea(detailFig);
            detailArea.Position = [16 16 728 472];
            detailArea.Editable = 'off';
            detailArea.FontName = 'Consolas';
            detailArea.Value = cellstr(splitlines(string(report)));
        end

        %% Status / progress

        function setStatus(app, msg, isError)
            app.StatusLine1Label.Text = char(msg);
            if isError
                app.StatusLine1Label.FontColor = [0.72 0.11 0.11];
            else
                app.StatusLine1Label.FontColor = [0.15 0.15 0.15];
            end
            drawnow;
        end

        function setProgressFraction(app, frac)
            frac = max(0, min(1, frac));
            trackWidth = app.ProgressTrackPanel.Position(3);
            pos = app.ProgressFillPanel.Position;
            pos(3) = max(1, round(frac * trackWidth));
            app.ProgressFillPanel.Position = pos;
        end

        function handleProgress(app, d)
            try
                config_count = (d.primary_idx - 1) * d.num_configs + d.config_idx;
                sim_count = config_count + (d.iter - 1) * d.num_primary * d.num_configs;
                config_length = d.num_primary * d.num_configs;
                sim_length = d.num_iters * config_length;
                setProgressFraction(app, sim_count / sim_length);

                % Full parameter listing + text progress bar, in the style
                % of PVP-IPFM's own updateProgressBar.m - printed to the
                % Command Window (copyable, scrollable, not truncated by a
                % single GUI label) rather than reconstructed here; see
                % print_progress_params.m for the flexible name/unit
                % lookup ("EbN0" -> "Eb/N0 = 16 dB", etc.).
                print_progress_params(d);

                app.StatusLine1Label.Text = sprintf('Config %d/%d - %s (%s) - frame %d/%d - full parameter list in Command Window', ...
                    config_count, config_length, d.system_name, d.receiver_name, ...
                    d.current_frames, d.num_frames);
                app.StatusLine1Label.FontColor = [0.15 0.15 0.15];
                drawnow limitrate;
            catch
                % A malformed progress packet should never abort the simulation.
            end
        end

        function handleConvergence(app, iter, num_iters, current_frames, n_sufficient, n_total)
            try
                app.StatusLine2Label.Text = sprintf('Iteration %d/%d (%d frames) - %d/%d points converged', ...
                    iter, num_iters, current_frames, n_sufficient, n_total);
                drawnow limitrate;
            catch
            end
        end

        %% Settings + run

        function settings = buildSettings(app)
            settings.table_name          = app.ResultsTableName;
            settings.use_parallel        = app.ParallelizationCheckBox.Value;
            settings.frames_per_iter     = app.TrialsPerIterationEditField.Value;
            settings.priority            = app.SavePriorityDropDown.Value;
            settings.save_mysql          = app.EnableMySQLCheckBox.Value;
            settings.save_excel          = app.SaveExcelCheckBox.Value;
            settings.profile_sel         = app.ProfileListBox.Value;
            settings.num_frames          = app.NumberofTrialsEditField.Value;
            settings.iteratively_render  = app.IterativelyRenderCheckBox.Value;
            settings.delete_sel          = app.DeleteSelectedConfigsCheckBox.Value;
            settings.figure_statistic    = app.FigureStatisticDropDown.Value;
            settings.enable_adaptive     = app.EnableAdaptiveCheckBox.Value;
            settings.relative_tolerance  = app.ToleranceEditField.Value;
            settings.min_frames          = app.MinFramesEditField.Value;
            settings.confidence          = app.ConfidenceDropDown.Value;
            settings.progress_fcn        = @(d) handleProgress(app, d);
            settings.convergence_fcn     = @(iter, num_iters, current_frames, n_suff, n_total) ...
                handleConvergence(app, iter, num_iters, current_frames, n_suff, n_total);
        end

        function SimulateButtonPushed(app, ~)
            if isempty(app.ProfileListBox.Value)
                setStatus(app, "Select a profile first.", true);
                return;
            end
            settings = buildSettings(app);
            setProgressFraction(app, 0);
            app.StatusLine2Label.Text = '';
            setStatus(app, "Simulating...", false);
            finish_flag = false;
            stopped_on_error = false;
            while ~finish_flag && ~stopped_on_error
                try
                    finish_flag = sim_head(settings);
                catch ME
                    if app.IgnoreErrorsCheckBox.Value
                        % Opt-in resilience for long unattended runs: log
                        % the full report (Command Window) so it isn't
                        % lost, but don't block the retry loop with a
                        % modal dialog every 5 seconds.
                        disp("===== Simulation error (ignored, retrying in 5s) =====");
                        disp(getReport(ME, 'extended', 'hyperlinks', 'off'));
                        setStatus(app, "Error: " + ME.message + " (retrying in 5s - see Command Window)", true);
                        pause(5);
                    else
                        setStatus(app, "Error - stopped. See error dialog for full details.", true);
                        showErrorDialog(app, ME);
                        stopped_on_error = true;
                    end
                end
            end
            if ~stopped_on_error
                setStatus(app, "Done.", false);
            end
        end

        function GenerateFigureButtonPushed(app, ~)
            if isempty(app.ProfileListBox.Value)
                setStatus(app, "Select a profile first.", true);
                return;
            end
            settings = buildSettings(app);
            settings.use_parallel       = false;
            settings.num_frames         = 0;
            settings.iteratively_render = false;
            settings.delete_sel         = false;
            % PROGRESS BAR (added 2026-09-23). Figure generation emits no
            % progress callbacks -- sim_head is called here with num_frames=0
            % and no progress_fcn -- so the bar cannot fill incrementally the
            % way it does for Run. It is used as a completion indicator
            % instead: cleared on entry so a stale fill from an earlier Run
            % cannot be mistaken for this action's state, then filled to 100%
            % (the fill panel is already green against a grey track) only once
            % sim_head has returned successfully.
            %
            % Cleared again on the error path on purpose. Leaving a full green
            % bar behind a failed render would assert success while the status
            % line says otherwise, and the bar is the more glanceable of the
            % two.
            setProgressFraction(app, 0);
            setStatus(app, "Generating figure...", false);
            try
                sim_head(settings);
                setProgressFraction(app, 1);   % full green = figure complete
                setStatus(app, "Figure generated.", false);
            catch ME
                setProgressFraction(app, 0);
                setStatus(app, "Error - see error dialog for full details.", true);
                showErrorDialog(app, ME);
            end
        end
    end

    % App lifecycle
    methods (Access = public)

        function app = WirelessSimulator
            createComponents(app);
            registerApp(app, app.UIFigure);
            runStartupFcn(app, @startupFcn);
            if nargout == 0
                clear app;
            end
        end

        function delete(app)
            delete(app.UIFigure);
        end
    end

    methods (Access = private)
        function createComponents(app)

            % Create figure
            app.UIFigure = uifigure('Visible', 'off');
            app.UIFigure.Position = [80 60 1054 560];   % widened 940->1054 on 2026-09-18 to fit the Frame Counts button beside Details without shrinking ProfileTitleLabel (which would clip long profile names)
            app.UIFigure.Name = 'Wireless Simulator';

            %% Sidebar
            app.SidebarPanel = uipanel(app.UIFigure);
            app.SidebarPanel.BorderType = 'line';
            app.SidebarPanel.Position = [10 10 240 540];

            app.ProfileHeaderLabel = uilabel(app.SidebarPanel);
            app.ProfileHeaderLabel.FontWeight = 'bold';
            app.ProfileHeaderLabel.FontSize = 11;
            app.ProfileHeaderLabel.Position = [10 505 150 20];
            app.ProfileHeaderLabel.Text = 'PROFILE';

            app.ProfileSearchField = uieditfield(app.SidebarPanel, 'text');
            app.ProfileSearchField.Position = [10 475 220 26];
            app.ProfileSearchField.Placeholder = 'Filter profiles...';
            app.ProfileSearchField.ValueChangingFcn = createCallbackFcn(app, @ProfileSearchFieldValueChanging, true);

            app.ProfileListBox = uilistbox(app.SidebarPanel);
            app.ProfileListBox.Position = [10 50 220 415];
            app.ProfileListBox.Items = {'(loading...)'};
            app.ProfileListBox.ItemsData = {0};
            app.ProfileListBox.ValueChangedFcn = createCallbackFcn(app, @ProfileListBoxValueChanged, true);

            app.ReloadProfilesButton = uibutton(app.SidebarPanel, 'push');
            app.ReloadProfilesButton.ButtonPushedFcn = createCallbackFcn(app, @ReloadProfilesButtonPushed, true);
            app.ReloadProfilesButton.Position = [10 10 220 30];
            app.ReloadProfilesButton.Text = 'Reload Profiles';

            %% Content header
            app.ProfileTitleLabel = uilabel(app.UIFigure);
            app.ProfileTitleLabel.FontWeight = 'bold';
            app.ProfileTitleLabel.FontSize = 15;
            app.ProfileTitleLabel.Position = [266 484 550 24];
            app.ProfileTitleLabel.Text = 'No profile selected';

            app.ProfileDetailsButton = uibutton(app.UIFigure, 'push');
            app.ProfileDetailsButton.ButtonPushedFcn = createCallbackFcn(app, @ProfileDetailsButtonPushed, true);
            app.ProfileDetailsButton.Position = [826 485 94 22];
            app.ProfileDetailsButton.Text = 'Details';
            app.ProfileDetailsButton.Tooltip = 'Open the full profile definition (parameters, configs, plot settings) in a new window.';

            % Frame Counts (2026-09-18): sits immediately right of Details.
            app.FrameCountsButton = uibutton(app.UIFigure, 'push');
            app.FrameCountsButton.ButtonPushedFcn = createCallbackFcn(app, @FrameCountsButtonPushed, true);
            app.FrameCountsButton.Position = [940 485 94 22];
            app.FrameCountsButton.Text = 'Frames';
            app.FrameCountsButton.Tooltip = 'Show how many frames are accumulated for every test point of this profile (rows = primary variable sweep, columns = configs).';

            app.ProfileSubtitleLabel = uilabel(app.UIFigure);
            app.ProfileSubtitleLabel.FontColor = [0.45 0.45 0.45];
            app.ProfileSubtitleLabel.Position = [266 460 778 20];
            app.ProfileSubtitleLabel.Text = '';

            %% Run card
            app.RunPanel = uipanel(app.UIFigure);
            app.RunPanel.Title = 'RUN';
            app.RunPanel.Position = [266 296 320 150];

            app.NumberofTrialsEditFieldLabel = uilabel(app.RunPanel);
            app.NumberofTrialsEditFieldLabel.HorizontalAlignment = 'right';
            app.NumberofTrialsEditFieldLabel.Position = [8 96 65 20];
            app.NumberofTrialsEditFieldLabel.Text = 'Frames';

            app.NumberofTrialsEditField = uieditfield(app.RunPanel, 'numeric');
            app.NumberofTrialsEditField.Position = [78 96 68 22];
            app.NumberofTrialsEditField.Limits = [0 Inf];
            app.NumberofTrialsEditField.Value = 2000;
            app.NumberofTrialsEditField.Tooltip = 'Total frames to simulate per point. 0 = skip simulating and only render a figure.';

            app.TrialsPerIterationEditFieldLabel = uilabel(app.RunPanel);
            app.TrialsPerIterationEditFieldLabel.HorizontalAlignment = 'right';
            app.TrialsPerIterationEditFieldLabel.Position = [154 96 78 20];
            app.TrialsPerIterationEditFieldLabel.Text = '/ Iteration';

            app.TrialsPerIterationEditField = uieditfield(app.RunPanel, 'numeric');
            app.TrialsPerIterationEditField.Position = [236 96 68 22];
            app.TrialsPerIterationEditField.Limits = [0 Inf];
            app.TrialsPerIterationEditField.Value = 10;
            app.TrialsPerIterationEditField.Tooltip = 'Frames simulated between each results save / figure refresh.';

            app.ParallelizationCheckBox = uicheckbox(app.RunPanel);
            app.ParallelizationCheckBox.Text = 'Parallelization';
            app.ParallelizationCheckBox.Position = [8 68 140 22];
            app.ParallelizationCheckBox.Value = false;

            app.IgnoreErrorsCheckBox = uicheckbox(app.RunPanel);
            app.IgnoreErrorsCheckBox.Text = 'Ignore Errors';
            app.IgnoreErrorsCheckBox.Position = [160 68 140 22];
            app.IgnoreErrorsCheckBox.Value = false;
            app.IgnoreErrorsCheckBox.Tooltip = 'If checked, automatically retry (after 5s) instead of stopping when a simulation errors out - full error details still go to the Command Window, but no dialog pops up each retry. Off by default so errors stop the run and show a full, copyable error dialog immediately (recommended while debugging).';

            app.IterativelyRenderCheckBox = uicheckbox(app.RunPanel);
            app.IterativelyRenderCheckBox.Text = 'Iteratively Render';
            app.IterativelyRenderCheckBox.Position = [8 40 150 22];
            app.IterativelyRenderCheckBox.Value = false;
            app.IterativelyRenderCheckBox.Tooltip = 'Redraw the figure after every batch of frames instead of only at the end.';

            app.DeleteSelectedConfigsCheckBox = uicheckbox(app.RunPanel);
            app.DeleteSelectedConfigsCheckBox.Text = 'Delete Selected Configs';
            app.DeleteSelectedConfigsCheckBox.Position = [8 12 220 22];
            app.DeleteSelectedConfigsCheckBox.Value = false;
            app.DeleteSelectedConfigsCheckBox.Tooltip = 'Erase and re-simulate any configs flagged in the profile''s delete_configs list.';

            %% Storage card
            app.StoragePanel = uipanel(app.UIFigure);
            app.StoragePanel.Title = 'STORAGE';
            app.StoragePanel.Position = [606 296 324 150];

            app.SavePriorityDropDownLabel = uilabel(app.StoragePanel);
            app.SavePriorityDropDownLabel.HorizontalAlignment = 'right';
            app.SavePriorityDropDownLabel.Position = [8 96 68 20];
            app.SavePriorityDropDownLabel.Text = 'Priority';

            app.SavePriorityDropDown = uidropdown(app.StoragePanel);
            app.SavePriorityDropDown.Position = [80 96 90 22];
            app.SavePriorityDropDown.Items = {'local', 'mysql'};
            app.SavePriorityDropDown.Value = 'mysql';
            app.SavePriorityDropDown.Tooltip = 'Which existing results to check first when resuming a partially-simulated profile.';

            app.EnableMySQLCheckBox = uicheckbox(app.StoragePanel);
            app.EnableMySQLCheckBox.Text = 'Enable MySQL';
            app.EnableMySQLCheckBox.Position = [8 68 130 22];
            app.EnableMySQLCheckBox.Value = true;

            app.SaveExcelCheckBox = uicheckbox(app.StoragePanel);
            app.SaveExcelCheckBox.Text = 'Save Excel';
            app.SaveExcelCheckBox.Position = [8 40 100 22];
            app.SaveExcelCheckBox.Value = false;

            resultsTableBox = uipanel(app.StoragePanel);
            resultsTableBox.BorderType = 'line';
            resultsTableBox.BackgroundColor = [0.957 0.973 0.984];
            resultsTableBox.Position = [8 6 300 28];

            app.ResultsTableCaptionLabel = uilabel(resultsTableBox);
            app.ResultsTableCaptionLabel.Position = [8 1 100 26];
            app.ResultsTableCaptionLabel.FontSize = 9;
            app.ResultsTableCaptionLabel.FontColor = [0.29 0.48 0.61];
            app.ResultsTableCaptionLabel.Text = 'RESULTS TABLE';

            app.ResultsTableValueLabel = uilabel(resultsTableBox);
            app.ResultsTableValueLabel.Position = [110 1 180 26];
            app.ResultsTableValueLabel.FontColor = [0.04 0.24 0.36];
            app.ResultsTableValueLabel.Text = app.ResultsTableName;
            app.ResultsTableValueLabel.Tooltip = 'Every project writes to this one shared, merged results table - it is not a per-run choice.';

            %% Adaptive stopping card
            app.ConvergencePanel = uipanel(app.UIFigure);
            app.ConvergencePanel.Title = 'ADAPTIVE STOPPING';
            app.ConvergencePanel.Position = [266 126 320 150];

            app.EnableAdaptiveCheckBox = uicheckbox(app.ConvergencePanel);
            app.EnableAdaptiveCheckBox.Text = 'Enable Adaptive Stopping';
            app.EnableAdaptiveCheckBox.Position = [8 96 220 22];
            app.EnableAdaptiveCheckBox.Value = false;
            app.EnableAdaptiveCheckBox.Tooltip = 'Stop simulating a point early once its metric estimate has converged, instead of always running the full frame count.';

            app.ToleranceEditFieldLabel = uilabel(app.ConvergencePanel);
            app.ToleranceEditFieldLabel.HorizontalAlignment = 'right';
            app.ToleranceEditFieldLabel.Position = [8 68 80 20];
            app.ToleranceEditFieldLabel.Text = 'Tolerance';

            app.ToleranceEditField = uieditfield(app.ConvergencePanel, 'numeric');
            app.ToleranceEditField.Position = [92 68 70 22];
            app.ToleranceEditField.Limits = [0 1];
            app.ToleranceEditField.Value = 0.1;

            app.MinFramesEditFieldLabel = uilabel(app.ConvergencePanel);
            app.MinFramesEditFieldLabel.HorizontalAlignment = 'right';
            app.MinFramesEditFieldLabel.Position = [172 68 80 20];
            app.MinFramesEditFieldLabel.Text = 'Min Frames';

            app.MinFramesEditField = uieditfield(app.ConvergencePanel, 'numeric');
            app.MinFramesEditField.Position = [256 68 56 22];
            app.MinFramesEditField.Limits = [0 Inf];
            app.MinFramesEditField.Value = 100;

            app.ConfidenceDropDownLabel = uilabel(app.ConvergencePanel);
            app.ConfidenceDropDownLabel.HorizontalAlignment = 'right';
            app.ConfidenceDropDownLabel.Position = [8 34 80 20];
            app.ConfidenceDropDownLabel.Text = 'Confidence';

            app.ConfidenceDropDown = uidropdown(app.ConvergencePanel);
            app.ConfidenceDropDown.Position = [92 34 70 22];
            app.ConfidenceDropDown.Items = {'0.90', '0.95', '0.99'};
            app.ConfidenceDropDown.ItemsData = {0.90, 0.95, 0.99};
            app.ConfidenceDropDown.Value = 0.95;

            %% Output card
            app.OutputPanel = uipanel(app.UIFigure);
            app.OutputPanel.Title = 'OUTPUT';
            app.OutputPanel.Position = [606 126 324 150];

            app.FigureStatisticDropDownLabel = uilabel(app.OutputPanel);
            app.FigureStatisticDropDownLabel.HorizontalAlignment = 'right';
            app.FigureStatisticDropDownLabel.Position = [8 96 90 20];
            app.FigureStatisticDropDownLabel.Text = 'Statistic';

            app.FigureStatisticDropDown = uidropdown(app.OutputPanel);
            app.FigureStatisticDropDown.Position = [102 96 140 22];
            app.FigureStatisticDropDown.Items = {'BER', 'SER', 'FER', 'Thr', 'RX_iters', 't_RXfull', 't_RXiter', 't_RXcpufull', 't_RXcpuiter', 't_ESTcpufull', 't_ESTcpuiter', 'recon_mse'};
            app.FigureStatisticDropDown.Value = 'BER';
            app.FigureStatisticDropDown.Tooltip = 'Overrides the profile''s own metric when rendering a figure. Leave as the profile default unless you need a different view.';

            %% Status strip
            app.ProgressTrackPanel = uipanel(app.UIFigure);
            app.ProgressTrackPanel.BorderType = 'line';
            app.ProgressTrackPanel.BackgroundColor = [0.87 0.87 0.87];
            app.ProgressTrackPanel.Position = [266 68 150 20];

            app.ProgressFillPanel = uipanel(app.ProgressTrackPanel);
            app.ProgressFillPanel.BorderType = 'none';
            app.ProgressFillPanel.BackgroundColor = [0.16 0.63 0.27];
            app.ProgressFillPanel.Position = [0 0 1 20];

            app.StatusLine1Label = uilabel(app.UIFigure);
            app.StatusLine1Label.Position = [426 68 618 22];
            app.StatusLine1Label.Text = 'Ready.';

            app.StatusLine2Label = uilabel(app.UIFigure);
            app.StatusLine2Label.Position = [266 42 778 18];
            app.StatusLine2Label.FontColor = [0.45 0.45 0.45];
            app.StatusLine2Label.FontSize = 11;
            app.StatusLine2Label.Text = '';

            %% Action buttons
            app.GenerateFigureButton = uibutton(app.UIFigure, 'push');
            app.GenerateFigureButton.ButtonPushedFcn = createCallbackFcn(app, @GenerateFigureButtonPushed, true);
            app.GenerateFigureButton.Position = [606 12 150 34];
            app.GenerateFigureButton.Text = 'Generate Figure';

            app.SimulateButton = uibutton(app.UIFigure, 'push');
            app.SimulateButton.ButtonPushedFcn = createCallbackFcn(app, @SimulateButtonPushed, true);
            app.SimulateButton.Position = [766 12 164 34];
            app.SimulateButton.Text = 'Simulate';
            app.SimulateButton.FontWeight = 'bold';

            % Show figure after all components created
            app.UIFigure.Visible = 'on';
        end
    end
end

function s = formatValueList(vals)
vals = vals(:)';
if isempty(vals)
    s = '(none)';
elseif isnumeric(vals) && numel(vals) <= 5
    s = char(strjoin(compose('%g', vals), ', '));
elseif isnumeric(vals)
    s = char(sprintf('%g, %g, ... %g (%d pts)', vals(1), vals(2), vals(end), numel(vals)));
else
    s = char(strjoin(string(vals), ', '));
end
end
