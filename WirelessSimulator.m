classdef WirelessSimulator < matlab.apps.AppBase
    % WirelessSimulator Unified GUI for all wireless communication projects.
    % Builds an app_settings struct and passes it to sim_head().
    %
    % Works with any project that implements saved_profiles() and sim_head(app_settings).

    % UI Components
    properties (Access = public)
        UIFigure                         matlab.ui.Figure
        DatabaseTableDropDown            matlab.ui.control.DropDown
        DatabaseTableDropDownLabel       matlab.ui.control.Label
        SavePriorityDropDown             matlab.ui.control.DropDown
        SavePriorityDropDownLabel        matlab.ui.control.Label
        EnableMySQLCheckBox              matlab.ui.control.CheckBox
        SaveExcelCheckBox                matlab.ui.control.CheckBox
        ParallelizationCheckBox          matlab.ui.control.CheckBox
        IterativelyRenderCheckBox        matlab.ui.control.CheckBox
        DeleteSelectedConfigsCheckBox    matlab.ui.control.CheckBox
        IgnoreErrorsCheckBox             matlab.ui.control.CheckBox
        NumberofTrialsEditField          matlab.ui.control.NumericEditField
        NumberofTrialsEditFieldLabel     matlab.ui.control.Label
        TrialsPerIterationEditField      matlab.ui.control.NumericEditField
        TrialsPerIterationEditFieldLabel matlab.ui.control.Label
        ProfileSelectDropDown            matlab.ui.control.DropDown
        ProfileSelectDropDownLabel       matlab.ui.control.Label
        FigureStatisticDropDown          matlab.ui.control.DropDown
        FigureStatisticDropDownLabel     matlab.ui.control.Label
        ReloadProfilesButton             matlab.ui.control.Button
        SimulateButton                   matlab.ui.control.Button
        GenerateFigureButton             matlab.ui.control.Button
    end

    % Callbacks
    methods (Access = private)

        function startupFcn(app)
            [~, profile_names] = saved_profiles();
            fprintf("\n+----+--------------------------------------+\n");
            fprintf("| #  | Profile Name                         |\n");
            fprintf("+----+--------------------------------------+\n");
            for i = 1:numel(profile_names)
                fprintf("| %2d | %-37s |\n", i, profile_names{i});
            end
            fprintf("+----+--------------------------------------+\n\n");
            app.ProfileSelectDropDown.Items = ...
                arrayfun(@num2str, 1:numel(profile_names), 'UniformOutput', false);
        end

        function settings = buildSettings(app)
            settings.table_name          = app.DatabaseTableDropDown.Value;
            settings.use_parallel        = app.ParallelizationCheckBox.Value;
            settings.frames_per_iter     = app.TrialsPerIterationEditField.Value;
            settings.priority            = app.SavePriorityDropDown.Value;
            settings.save_mysql          = app.EnableMySQLCheckBox.Value;
            settings.save_excel          = app.SaveExcelCheckBox.Value;
            settings.profile_sel         = str2double(app.ProfileSelectDropDown.Value);
            settings.num_frames          = app.NumberofTrialsEditField.Value;
            settings.iteratively_render  = app.IterativelyRenderCheckBox.Value;
            settings.delete_sel          = app.DeleteSelectedConfigsCheckBox.Value;
            settings.figure_statistic    = app.FigureStatisticDropDown.Value;
        end

        function SimulateButtonPushed(app, ~)
            settings = buildSettings(app);
            finish_flag = false;
            while ~finish_flag
                if app.IgnoreErrorsCheckBox.Value
                    try
                        finish_flag = sim_head(settings);
                    catch ME
                        fprintf("Error: %s\nRetry in 5s...\n", ME.message);
                        pause(5);
                    end
                else
                    finish_flag = sim_head(settings);
                end
            end
        end

        function GenerateFigureButtonPushed(app, ~)
            settings = buildSettings(app);
            settings.use_parallel       = false;
            settings.num_frames         = 0;
            settings.iteratively_render = false;
            settings.delete_sel         = false;
            sim_head(settings);
        end

        function ReloadProfilesButtonPushed(app, ~)
            startupFcn(app);
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
            app.UIFigure.Position = [100 100 400 400];
            app.UIFigure.Name = 'Wireless Simulator';

            % Database Table (y=363)
            app.DatabaseTableDropDownLabel = uilabel(app.UIFigure);
            app.DatabaseTableDropDownLabel.HorizontalAlignment = 'right';
            app.DatabaseTableDropDownLabel.Position = [91 363 88 22];
            app.DatabaseTableDropDownLabel.Text = 'Database Table';

            app.DatabaseTableDropDown = uidropdown(app.UIFigure);
            app.DatabaseTableDropDown.Position = [194 363 116 22];
            app.DatabaseTableDropDown.Items = {'results_TWC', 'OTFS_Journal', 'results_MUSIC', 'results_ODDM'};
            app.DatabaseTableDropDown.Value = 'results_TWC';

            % Save Priority (y=331)
            app.SavePriorityDropDownLabel = uilabel(app.UIFigure);
            app.SavePriorityDropDownLabel.HorizontalAlignment = 'right';
            app.SavePriorityDropDownLabel.Position = [106 331 73 22];
            app.SavePriorityDropDownLabel.Text = 'Save Priority';

            app.SavePriorityDropDown = uidropdown(app.UIFigure);
            app.SavePriorityDropDown.Position = [194 331 100 22];
            app.SavePriorityDropDown.Items = {'local', 'mysql'};
            app.SavePriorityDropDown.Value = 'local';

            % Enable MySQL (y=310)
            app.EnableMySQLCheckBox = uicheckbox(app.UIFigure);
            app.EnableMySQLCheckBox.Text = 'Enable MySQL';
            app.EnableMySQLCheckBox.Position = [109 310 103 22];
            app.EnableMySQLCheckBox.Value = false;

            % Save Excel (y=289)
            app.SaveExcelCheckBox = uicheckbox(app.UIFigure);
            app.SaveExcelCheckBox.Text = 'Save Excel';
            app.SaveExcelCheckBox.Position = [109 289 82 22];
            app.SaveExcelCheckBox.Value = true;

            % Trials per Iteration (y=260)
            app.TrialsPerIterationEditFieldLabel = uilabel(app.UIFigure);
            app.TrialsPerIterationEditFieldLabel.HorizontalAlignment = 'right';
            app.TrialsPerIterationEditFieldLabel.Position = [67 260 112 22];
            app.TrialsPerIterationEditFieldLabel.Text = 'Trials per Iteration';

            app.TrialsPerIterationEditField = uieditfield(app.UIFigure, 'numeric');
            app.TrialsPerIterationEditField.Position = [197 260 100 22];
            app.TrialsPerIterationEditField.Limits = [0 Inf];
            app.TrialsPerIterationEditField.Value = 10;

            % Parallelization (y=230)
            app.ParallelizationCheckBox = uicheckbox(app.UIFigure);
            app.ParallelizationCheckBox.Text = 'Parallelization';
            app.ParallelizationCheckBox.Position = [89 230 97 22];
            app.ParallelizationCheckBox.Value = false;

            % Reload Profiles (y=195)
            app.ReloadProfilesButton = uibutton(app.UIFigure, 'push');
            app.ReloadProfilesButton.ButtonPushedFcn = createCallbackFcn(app, @ReloadProfilesButtonPushed, true);
            app.ReloadProfilesButton.Position = [89 195 100 23];
            app.ReloadProfilesButton.Text = 'Reload Profiles';

            % Iteratively Render (y=195)
            app.IterativelyRenderCheckBox = uicheckbox(app.UIFigure);
            app.IterativelyRenderCheckBox.Text = 'Iteratively Render';
            app.IterativelyRenderCheckBox.Position = [197 195 116 22];
            app.IterativelyRenderCheckBox.Value = false;

            % Delete Selected Configs (y=168)
            app.DeleteSelectedConfigsCheckBox = uicheckbox(app.UIFigure);
            app.DeleteSelectedConfigsCheckBox.Text = 'Delete Selected Configs';
            app.DeleteSelectedConfigsCheckBox.Position = [89 168 150 22];
            app.DeleteSelectedConfigsCheckBox.Value = false;

            % Ignore Errors (y=140)
            app.IgnoreErrorsCheckBox = uicheckbox(app.UIFigure);
            app.IgnoreErrorsCheckBox.Text = 'Ignore Errors';
            app.IgnoreErrorsCheckBox.Position = [89 140 103 22];
            app.IgnoreErrorsCheckBox.Value = true;

            % Figure Statistic (y=108)
            app.FigureStatisticDropDownLabel = uilabel(app.UIFigure);
            app.FigureStatisticDropDownLabel.HorizontalAlignment = 'right';
            app.FigureStatisticDropDownLabel.Position = [84 108 95 22];
            app.FigureStatisticDropDownLabel.Text = 'Figure Statistic';

            app.FigureStatisticDropDown = uidropdown(app.UIFigure);
            app.FigureStatisticDropDown.Position = [194 108 116 22];
            app.FigureStatisticDropDown.Items = {'BER', 'SER', 'FER', 'Thr', 'RX_iters', 't_RXfull', 't_RXiter', 'recon_mse'};
            app.FigureStatisticDropDown.Value = 'BER';

            % Number of Trials (y=75)
            app.NumberofTrialsEditFieldLabel = uilabel(app.UIFigure);
            app.NumberofTrialsEditFieldLabel.HorizontalAlignment = 'right';
            app.NumberofTrialsEditFieldLabel.Position = [88 75 91 22];
            app.NumberofTrialsEditFieldLabel.Text = 'Number of Trials';

            app.NumberofTrialsEditField = uieditfield(app.UIFigure, 'numeric');
            app.NumberofTrialsEditField.Position = [197 75 100 22];
            app.NumberofTrialsEditField.Limits = [0 Inf];
            app.NumberofTrialsEditField.Value = 100;

            % Profile Select (y=46)
            app.ProfileSelectDropDownLabel = uilabel(app.UIFigure);
            app.ProfileSelectDropDownLabel.HorizontalAlignment = 'right';
            app.ProfileSelectDropDownLabel.Position = [106 46 76 22];
            app.ProfileSelectDropDownLabel.Text = 'Profile Select';

            app.ProfileSelectDropDown = uidropdown(app.UIFigure);
            app.ProfileSelectDropDown.Position = [197 46 100 22];
            app.ProfileSelectDropDown.Items = {'1'};
            app.ProfileSelectDropDown.Value = '1';

            % Simulate button (y=15)
            app.SimulateButton = uibutton(app.UIFigure, 'push');
            app.SimulateButton.ButtonPushedFcn = createCallbackFcn(app, @SimulateButtonPushed, true);
            app.SimulateButton.Position = [88 15 100 23];
            app.SimulateButton.Text = 'Simulate';

            % Generate Figure button (y=15)
            app.GenerateFigureButton = uibutton(app.UIFigure, 'push');
            app.GenerateFigureButton.ButtonPushedFcn = createCallbackFcn(app, @GenerateFigureButtonPushed, true);
            app.GenerateFigureButton.Position = [194 15 102 23];
            app.GenerateFigureButton.Text = 'Generate Figure';

            % Show figure after all components created
            app.UIFigure.Visible = 'on';
        end
    end
end
