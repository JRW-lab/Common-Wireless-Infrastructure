function tf = mysql_is_permanent_failure(ME)
% MYSQL_IS_PERMANENT_FAILURE True for database errors that waiting cannot fix.
%
%   tf = mysql_is_permanent_failure(ME)
%
%   Used by the resilient helpers to decide whether to keep retrying. A
%   wrong password or a disabled MySQL config would otherwise loop forever
%   and hide a setup mistake. Matched on message text because the Database
%   Toolbox reports most JDBC errors under one generic identifier.
%
%   Unrecognised errors are treated as TRANSIENT on purpose: an unattended
%   run should survive a network error this list does not name.
%
%   INPUTS:
%     ME: MException caught from a connection or query attempt

% Signatures that more waiting cannot clear
permanent = [ ...
    "Access denied", ...
    "MySQL is not configured", ...
    "is not configured for this project", ...
    "no database name is available"];

% Match against the message text
msg = string(ME.message);
tf  = any(arrayfun(@(p) contains(msg, p, 'IgnoreCase', true), permanent));

end
