--
-- PostgreSQL database dump
--

-- Dumped from database version 13.5 (Debian 13.5-0+deb11u1)
-- Dumped by pg_dump version 13.5 (Debian 13.5-0+deb11u1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: cov_visible_name; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.cov_visible_name (
    uid integer NOT NULL,
    operator character varying(200),
    visible_name character varying(50)
);


ALTER TABLE public.cov_visible_name OWNER TO postgres;

--
-- Name: cov_visible_name_uid_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.cov_visible_name_uid_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.cov_visible_name_uid_seq OWNER TO postgres;

--
-- Name: cov_visible_name_uid_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.cov_visible_name_uid_seq OWNED BY public.cov_visible_name.uid;


--
-- Name: cov_visible_name uid; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cov_visible_name ALTER COLUMN uid SET DEFAULT nextval('public.cov_visible_name_uid_seq'::regclass);


--
-- Data for Name: cov_visible_name; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.cov_visible_name (uid, operator, visible_name) FROM stdin;
\.


--
-- Name: cov_visible_name_uid_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.cov_visible_name_uid_seq', 1, false);


--
-- Name: cov_visible_name cov_visible_name_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cov_visible_name
    ADD CONSTRAINT cov_visible_name_pkey PRIMARY KEY (uid);


--
-- Name: cov_visible_name_visible_name_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX cov_visible_name_visible_name_idx ON public.cov_visible_name USING btree (visible_name);


--
-- Name: TABLE cov_visible_name; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.cov_visible_name TO web_anon;


--
-- PostgreSQL database dump complete
--

