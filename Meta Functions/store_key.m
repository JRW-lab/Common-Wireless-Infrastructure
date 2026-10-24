function k = store_key(st)
% STORE_KEY  One store's name in store_status.json: "priority|kind|where".
%
%   k = store_key(st)   st: one machine_stores element
%
%   "where" is the file or folder path for file stores and host/dbname.table
%   for MySQL, so two stores of one computer never share a key.

% Where the store lives
if st.kind == "mysql"
    w = st.host + "/" + st.dbname + "." + st.table;
else
    w = st.path;
end
k = sprintf('%d|%s|%s', st.priority, st.kind, w);
end
