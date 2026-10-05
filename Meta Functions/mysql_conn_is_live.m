function tf = mysql_conn_is_live(conn)
%MYSQL_CONN_IS_LIVE  True only if the server still answers on this connection.
%
%   isopen(conn) is NOT sufficient. It inspects the client-side handle and
%   knows nothing about the server having closed the connection underneath
%   it -- which MySQL does after `wait_timeout` seconds idle (8 hours by
%   default). A handle in that state reports isopen == true and then throws
%   on the first real query:
%
%     "The last packet successfully received from the server was
%      42,851,106 milliseconds ago ... is longer than the server
%      configured value of 'wait_timeout'"
%
%   This function settles it the only way that actually works: by asking
%   the server something and seeing whether it answers.
%
%   Cost is one sub-millisecond round trip on the LAN, which is nothing
%   against the TCP connect + authentication (+ reverse-DNS lookup on
%   servers without skip-name-resolve) that connection caching exists to
%   avoid.

tf = false;
if isempty(conn)
    return;
end
try
    if ~isopen(conn)
        return;
    end
    % Cheapest possible round trip. Any answer at all means the socket is
    % still alive end-to-end.
    fetch(conn, "SELECT 1");
    tf = true;
catch
    % Any failure here means unusable, whatever the cause. The caller's job
    % is to reconnect, not to classify the corpse.
    tf = false;
end
end
