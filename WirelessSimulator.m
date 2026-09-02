classdef WirelessSimulator < matlab.apps.AppBase
    % WirelessSimulator Unified GUI for all wireless communication projects.
    % Builds an app_settings struct and passes it to sim_head().
    %
    % Works with any project that implements saved_profiles() and sim_head(app_settings).

    % UI Components
    properties (Access = public)
        UIFigure                         matlab.ui.Figure
        DataPanel                        matlab.ui.container.Panel
        DatabaseTableDropDown            matlab.ui.control.DropDown
        DatabaseTableDropDownLabel       matlab.ui.control.Label
        SavePriorityDropDown             matlab.ui.control.DropDown
        SavePriorityDropDownLabel        matlab.ui.control.Label
        EnableMySQLCheckBox              matlab.ui.control.CheckBox
        SaveExcelCheckBox                matlab.ui.control.CheckBox
        SimPanel                         matlab.ui.container.Panel
        ProfileSelectDropDown            matlab.ui.control.DropDown
        ProfileSelectDropDownLabel       matlab.ui.control.Label
        ReloadProfilesButton             matlab.ui.control.Button
        IterativelyRenderCheckBox        matlab.ui.control.CheckBox
        NumberofTrialsEditField          matlab.ui.control.NumericEditField
        NumberofTrialsEditFieldLabel     matlab.ui.control.Label
        TrialsPerIterationEditField      matlab.ui.control.NumericEditField
        TrialsPerIterationEditFieldLabel matlab.ui.control.Label
        ParallelizationCheckBox          matlab.ui.control.CheckBox
        IgnoreErrorsCheckBox             matlab.ui.control.CheckBox
        DeleteSelectedConfigsCheckBox    matlab.ui.control.CheckBox
        ConvergencePanel                 matlab.ui.container.Panel
        EnableAdaptiveCheckBox           matlab.ui.control.CheckBox
        ToleranceEditField               matlab.ui.control.NumericEditField
        ToleranceEditFieldLabel          matlab.ui.control.Label
        MinFramesEditField               matlab.ui.control.NumericEditField
        MinFramesEditFieldLabel          matlab.ui.control.Label
        ConfidenceDropDown               matlab.ui.control.DropDown
        ConfidenceDropDownLabel          matlab.ui.control.Label
        FigurePanel                      matlab.ui.container.Panel
        FigureStatisticDropDown          matlab.ui.control.DropDown
        FigureStatisticDropDownLabel     matlab.ui.control.Label
        StatusLabel                      matlab.ui.control.Label
        SimulateButton                   matlab.ui.control.Button
        GenerateFigureButton             matlab.ui.control.Button
    end

    % Callbacks
    methods (Access = private)

        function startupFcn(app)
            refreshProfiles(app);
            refreshDatabaseTables(app);
            setStatus(app, "Ready.", false);
        end

        function refreshProfiles(app)
            [~, profile_names] = saved_profiles();
            app.ProfileSelectDropDown.Items = profile_names;
            app.ProfileSelectDropDown.ItemsData = num2cell(1:numel(profile_names));
            if ~isempty(profile_names)
                app.ProfileSelectDropDown.Value = 1;
            end
        end

        function refreshDatabaseTables(app)
            % Populate known table names from any Excel files already saved
            % under Data/, so the dropdown reflects this project's actual
            % history instead of a hardcoded, cross-project list.
            found = {};
            if isfolder('Data')
                listing = dir(fullfile('Data', '*.xlsx'));
                for i = 1:numel(listing)
                    [~, name] = fileparts(listing(i).name);
                    if ~startsWith(name, '~')
                        found{end+1} = name; %#ok<AGROW>
                    end
                end
            end
            current = app.DatabaseTableDropDown.Value;
            items = unique([found, {current}], 'stable');
            app.DatabaseTableDropDown.Items = items;
            app.DatabaseTableDropDown.Value = current;
        end

        function setStatus(app, msg, isError)
            app.StatusLabel.Text = char(msg);
            if isError
                app.StatusLabel.FontColor = [0.72 0.11 0.11];
            else
                app.StatusLabel.FontColor = [0.15 0.15 0.15];
            end
            drawnow;
        end

        function settings = buildSettings(app)
            settings.table_name          = app.DatabaseTableDropDown.Value;
            settings.use_parallel        = app.ParallelizationCheckBox.Value;
            settings.frames_per_iter     = app.TrialsPerIterationEditField.Value;
            settings.priority            = app.SavePriorityDropDown.Value;
            settings.save_mysql          = app.EnableMySQLCheckBox.Value;
            settings.save_excel          = app.SaveExcelCheckBox.Value;
            settings.profile_sel         = app.ProfileSelectDropDown.Value;
            settings.num_frames          = app.NumberofTrialsEditField.Value;
            settings.iteratively_render  = app.IterativelyRenderCheckBox.Value;
            settings.delete_sel          = app.DeleteSelectedConfigsCheckBox.Value;
            settings.figure_statistic    = app.FigureStatisticDropDown.Value;
            settings.enable_adaptive     = app.EnableAdaptiveCheckBox.Value;
            settings.relative_tolerance  = app.ToleranceEditField.Value;
            settings.min_frames          = app.MinFramesEditField.Value;
            settings.confidence          = app.ConfidenceDropDown.Value;
        end

        function SimulateButtonPushed(app, ~)
            settings = buildSettings(app);
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
            refreshDatabaseTables(app);
            setStatus(app, "Done.", false);
        end

        function GenerateFigureButtonPushed(app, ~)
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

        function ReloadProfilesButtonPushed(app, ~)
            refreshProfiles(app);
            setStatus(app, "Profiles reloaded.", false);
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
            app.UIFigure.Position = [100 60 460 660];
            app.UIFigure.Name = 'Wireless Simulator';

            %% Data & Storage panel
            app.DataPanel = uipanel(app.UIFigure);
            app.DataPanel.Title = 'Data & Storage';
            app.DataPanel.Position = [20 540 420 100];

            app.DatabaseTableDropDownLabel = uilabel(app.DataPanel);
            app.DatabaseTableDropDownLabel.HorizontalAlignment = 'right';
            app.DatabaseTableDropDownLabel.Position = [10 52 88 22];
            app.DatabaseTableDropDownLabel.Text = 'Database Table';

            app.DatabaseTableDropDown = uidropdown(app.DataPanel);
            app.DatabaseTableDropDown.Position = [108 52 200 22];
            app.DatabaseTableDropDown.Editable = 'on';
            app.DatabaseTableDropDown.Items = {'results_TWC'};
            app.DatabaseTableDropDown.Value = 'results_TWC';
            app.DatabaseTableDropDown.Tooltip = 'Name of the Excel sheet / SQL table results are stored in. Type a new name to start a fresh table.';

            app.SavePriorityDropDownLabel = uilabel(app.DataPanel);
            app.SavePriorityDropDownLabel.HorizontalAlignment = 'right';
            app.SavePriorityDropDownLabel.Position = [25 24 73 22];
            app.SavePriorityDropDownLabel.Text = 'Save Priority';

            app.SavePriorityDropDown = uidropdown(app.DataPanel);
            app.SavePriorityDropDown.Position = [108 24 100 22];
            app.SavePriorityDropDown.Items = {'local', 'mysql'};
            app.SavePriorityDropDown.Value = 'local';
            app.SavePriorityDropDown.Tooltip = 'Which existing results to check first when resuming a partially-simulated profile.';

            app.EnableMySQLCheckBox = uicheckbox(app.DataPanel);
            app.EnableMySQLCheckBox.Text = 'Enable MySQL';
            app.EnableMySQLCheckBox.Position = [228 24 103 22];
            app.EnableMySQLCheckBox.Value = false;

            app.SaveExcelCheckBox = uicheckbox(app.DataPanel);
            app.SaveExcelCheckBox.Text = 'Save Excel';
            app.SaveExcelCheckBox.Position = [330 24 82 22];
            app.SaveExcelCheckBox.Value = true;

            %% Simulation panel
            app.SimPanel = uipanel(app.UIFigure);
            app.SimPanel.Title = 'Simulation';
            app.SimPanel.Position = [20 320 420 210];

            app.ProfileSelectDropDownLabel = uilabel(app.SimPanel);
            app.ProfileSelectDropDownLabel.HorizontalAlignment = 'right';
            app.ProfileSelectDropDownLabel.Position = [10 162 76 22];
            app.ProfileSelectDropDownLabel.Text = 'Profile Select';

            app.ProfileSelectDropDown = uidropdown(app.SimPanel);
            app.ProfileSelectDropDown.Position = [96 162 250 22];
            app.ProfileSelectDropDown.Items = {'1'};
            app.ProfileSelectDropDown.ItemsData = {1};
            app.ProfileSelectDropDown.Value = 1;

            app.ReloadProfilesButton = uibutton(app.SimPanel, 'push');
            app.ReloadProfilesButton.ButtonPushedFcn = createCallbackFcn(app, @ReloadProfilesButtonPushed, true);
            app.ReloadProfilesButton.Position = [10 130 130 23];
            app.ReloadProfilesButton.Text = 'Reload Profiles';

            app.IterativelyRenderCheckBox = uicheckbox(app.SimPanel);
            app.IterativelyRenderCheckBox.Text = 'Iteratively Render';
            app.IterativelyRenderCheckBox.Position = [160 130 130 22];
            app.IterativelyRenderCheckBox.Value = false;
            app.IterativelyRenderCheckBox.Tooltip = 'Redraw the figure after every batch of frames instead of only at the end.';

            app.NumberofTrialsEditFieldLabel = uilabel(app.SimPanel);
            app.NumberofTrialsEditFieldLabel.HorizontalAlignment = 'right';
            app.NumberofTrialsEditFieldLabel.Position = [0 98 96 22];
            app.NumberofTrialsEditFieldLabel.Text = 'Number of Frames';

            app.NumberofTrialsEditField = uieditfield(app.SimPanel, 'numeric');
            app.NumberofTrialsEditField.Position = [106 98 90 22];
            app.NumberofTrialsEditField.Limits = [0 Inf];
            app.NumberofTrialsEditField.Value = 2000;
            app.NumberofTrialsEditField.Tooltip = 'Total frames to simulate per point. 0 = skip simulating and only render a figure.';

            app.TrialsPerIterationEditFieldLabel = uilabel(app.SimPanel);
            app.TrialsPerIterationEditFieldLabel.HorizontalAlignment = 'right';
            app.TrialsPerIterationEditFieldLabel.Position = [206 98 100 22];
            app.TrialsPerIterationEditFieldLabel.Text = 'Frames/Iteration';

            app.TrialsPerIterationEditField = uieditfield(app.SimPanel, 'numeric');
            app.TrialsPerIterationEditField.Position = [312 98 90 22];
            app.TrialsPerIterationEditField.Limits = [0 Inf];
            app.TrialsPerIterationEditField.Value = 10;
            app.TrialsPerIterationEditField.Tooltip = 'Frames simulated between each results save / figure refresh.';

            app.ParallelizationCheckBox = uicheckbox(app.SimPanel);
            app.ParallelizationCheckBox.Text = 'Parallelization';
            app.ParallelizationCheckBox.Position = [10 66 100 22];
            app.ParallelizationCheckBox.Value = false;

            app.IgnoreErrorsCheckBox = uicheckbox(app.SimPanel);
            app.IgnoreErrorsCheckBox.Text = 'Ignore Errors';
            app.IgnoreErrorsCheckBox.Position = [160 66 100 22];
            app.IgnoreErrorsCheckBox.Value = true;
            app.IgnoreErrorsCheckBox.Tooltip = 'Automatically retry (after 5s) instead of stopping the GUI if a simulation errors out.';

            app.DeleteSelectedConfigsCheckBox = uicheckbox(app.SimPanel);
            app.DeleteSelectedConfigsCheckBox.Text = 'Delete Selected Configs';
            app.DeleteSelectedConfigsCheckBox.Position = [10 34 170 22];
            app.DeleteSelectedConfigsCheckBox.Value = false;
            app.DeleteSelectedConfigsCheckBox.Tooltip = 'Erase and re-simulate any configs flagged in the profile''s delete_configs list.';

            %% Convergence panel
            app.ConvergencePanel = uipanel(app.UIFigure);
            app.ConvergencePanel.Title = 'Adaptive Stopping (optional)';
            app.ConvergencePanel.Position = [20 190 420 120];

            app.EnableAdaptiveCheckBox = uicheckbox(app.ConvergencePanel);
            app.EnableAdaptiveCheckBox.Text = 'Enable Adaptive Stopping';
            app.EnableAdaptiveCheckBox.Position = [10 68 170 22];
            app.EnableAdaptiveCheckBox.Value = false;
            app.EnableAdaptiveCheckBox.Tooltip = 'Stop simulating a point early once its metric estimate has converged, instead of always running the full frame count.';

            app.ToleranceEditFieldLabel = uilabel(app.ConvergencePanel);
            app.ToleranceEditFieldLabel.HorizontalAlignment = 'right';
            app.ToleranceEditFieldLabel.Position = [0 36 105 22];
            app.ToleranceEditFieldLabel.Text = 'Relative Tolerance';

            app.ToleranceEditField = uieditfield(app.ConvergencePanel, 'numeric');
            app.ToleranceEditField.Position = [115 36 80 22];
            app.ToleranceEditField.Limits = [0 1];
            app.ToleranceEditField.Value = 0.1;

            app.MinFramesEditFieldLabel = uilabel(app.ConvergencePanel);
            app.MinFramesEditFieldLabel.HorizontalAlignment = 'right';
            app.MinFramesEditFieldLabel.Position = [205 36 80 22];
            app.MinFramesEditFieldLabel.Text = 'Min Frames';

            app.MinFramesEditField = uieditfield(app.ConvergencePanel, 'numeric');
            app.MinFramesEditField.Position = [295 36 100 22];
            app.MinFramesEditField.Limits = [0 Inf];
            app.MinFramesEditField.Value = 100;

            app.ConfidenceDropDownLabel = uilabel(app.ConvergencePanel);
            app.ConfidenceDropDownLabel.HorizontalAlignment = 'right';
            app.ConfidenceDropDownLabel.Position = [10 4 95 22];
            app.ConfidenceDropDownLabel.Text = 'Confidence';

            app.ConfidenceDropDown = uidropdown(app.ConvergencePanel);
            app.ConfidenceDropDown.Position = [115 4 80 22];
            app.ConfidenceDropDown.Items = {'0.90', '0.95', '0.99'};
            app.ConfidenceDropDown.ItemsData = {0.90, 0.95, 0.99};
            app.ConfidenceDropDown.Value = 0.95;

            %% Figure Output panel
            app.FigurePanel = uipanel(app.UIFigure);
            app.FigurePanel.Title = 'Figure Output';
            app.FigurePanel.Position = [20 130 420 50];

            app.FigureStatisticDropDownLabel = uilabel(app.FigurePanel);
            app.FigureStatisticDropDownLabel.HorizontalAlignment = 'right';
            app.FigureStatisticDropDownLabel.Position = [10 4 95 22];
            app.FigureStatisticDropDownLabel.Text = 'Figure Statistic';

            app.FigureStatisticDropDown = uidropdown(app.FigurePanel);
            app.FigureStatisticDropDown.Position = [115 4 130 22];
            app.FigureStatisticDropDown.Items = {'BER', 'SER', 'FER', 'Thr', 'RX_iters', 't_RXfull', 't_RXiter', 'recon_mse'};
            app.FigureStatisticDropDown.Value = 'BER';
            app.FigureStatisticDropDown.Tooltip = 'Overrides the profile''s own metric when rendering a figure. Leave as the profile default unless you need a different view.';

            %% Status line
            app.StatusLabel = uilabel(app.UIFigure);
            app.StatusLabel.Position = [20 90 420 22];
            app.StatusLabel.HorizontalAlignment = 'center';
            app.StatusLabel.Text = 'Ready.';

            %% Action buttons
            app.SimulateButton = uibutton(app.UIFigure, 'push');
            app.SimulateButton.ButtonPushedFcn = createCallbackFcn(app, @SimulateButtonPushed, true);
            app.SimulateButton.Position = [20 45 200 34];
            app.SimulateButton.Text = 'Simulate';
            app.SimulateButton.FontWeight = 'bold';

            app.GenerateFigureButton = uibutton(app.UIFigure, 'push');
            app.GenerateFigureButton.ButtonPushedFcn = createCallbackFcn(app, @GenerateFigureButtonPushed, true);
            app.GenerateFigureButton.Position = [240 45 200 34];
            app.GenerateFigureButton.Text = 'Generate Figure';

            % Show figure after all components created
            app.UIFigure.Visible = 'on';
        end
    end
end
