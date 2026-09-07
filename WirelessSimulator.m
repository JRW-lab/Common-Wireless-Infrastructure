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
                items{k} = sprintf('%s\n%s', names{i}, profileSubtitle(app, app.AllProfiles{i}));
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
                app.StatusLine1Label.Text = sprintf('Config %d/%d - %s (%s) - frame %d/%d', ...
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
            while ~finish_flag
                if app.IgnoreErrorsCheckBox.Value
                    try
                        finish_flag = sim_head(settings);
                    catch ME
                        setStatus(app, "Error: " + ME.message + " (retrying in 5s...)", true);
                        pause(5);
                    end
                else
                    finish_flag = sim_head(settings);
                end
            end
            setStatus(app, "Done.", false);
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
            setStatus(app, "Generating figure...", false);
            try
                sim_head(settings);
                setStatus(app, "Figure generated.", false);
            catch ME
                setStatus(app, "Error: " + ME.message, true);
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
            app.UIFigure.Position = [80 60 940 560];
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

            app.ProfileSubtitleLabel = uilabel(app.UIFigure);
            app.ProfileSubtitleLabel.FontColor = [0.45 0.45 0.45];
            app.ProfileSubtitleLabel.Position = [266 460 664 20];
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
            app.IgnoreErrorsCheckBox.Value = true;
            app.IgnoreErrorsCheckBox.Tooltip = 'Automatically retry (after 5s) instead of stopping the GUI if a simulation errors out.';

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
            app.FigureStatisticDropDown.Items = {'BER', 'SER', 'FER', 'Thr', 'RX_iters', 't_RXfull', 't_RXiter', 'recon_mse'};
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
            app.StatusLine1Label.Position = [426 68 504 22];
            app.StatusLine1Label.Text = 'Ready.';

            app.StatusLine2Label = uilabel(app.UIFigure);
            app.StatusLine2Label.Position = [266 42 664 18];
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
