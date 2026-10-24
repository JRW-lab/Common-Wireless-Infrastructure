function r = cws_root()
% CWS_ROOT  The Common Wireless Simulator folder, wherever the repository was cloned.
%
%   r = cws_root()
%
%   Infrastructure code used to name C:/MATLAB Projects/Common Wireless
%   Simulator outright, which only exists on the Windows computers. This
%   finds the root from this file's own location instead:
%   <root>/Common-Wireless-Infrastructure/Meta Functions/cws_root.m (Linux
%   port, 2026-10-22; notes INFRASTRUCTURE_OVERVIEW).
%
%   OUTPUT:
%     r: char, the root folder, with the platform's separators
%
%   LIMITS: scripts that run before this folder is on the path find the
%   root from their own location (fileparts of mfilename) instead.

% Three levels up from this file
r = fileparts(fileparts(fileparts(mfilename('fullpath'))));
end
