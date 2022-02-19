create schema api;
create role web_anon nologin;
grant usage on schema api to web_anon;
create role authenticator noinherit login password 'samepasswordasinpostgrest';
grant web_anon to authenticator;
