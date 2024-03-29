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
-- Name: setting_options; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.setting_options (
    uid integer NOT NULL,
    object character varying,
    filter jsonb
);


ALTER TABLE public.setting_options OWNER TO postgres;

--
-- Name: setting_options_uid_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.setting_options_uid_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.setting_options_uid_seq OWNER TO postgres;

--
-- Name: setting_options_uid_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.setting_options_uid_seq OWNED BY public.setting_options.uid;


--
-- Name: setting_options uid; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.setting_options ALTER COLUMN uid SET DEFAULT nextval('public.setting_options_uid_seq'::regclass);


--
-- Data for Name: setting_options; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.setting_options (uid, object, filter) FROM stdin;
1	settings	{"bands": [{"name": "@all", "default": true, "reference": "F1/16"}, {"name": "@3400mhz", "default": false, "reference": "F7/16"}], "timeline": [{"date": "2021-03-31"}, {"date": "2021-04-01"}, {"date": "2021-05-05"}], "operators": [{"label": "@all", "default": true, "operator": null}, {"label": "A1 Telekom Austria AG", "default": false, "operator": "A1TA"}, {"label": "T-Mobile Austria GmbH", "default": false, "operator": "TMA"}, {"label": "Hutchison Drei Austria GmbH", "default": false, "operator": "H3A"}, {"label": "LIWEST Kabelmedien GmbH", "default": false, "operator": "LIWEST"}, {"label": "Salzburg AG für Energie, Verkehr und Telekommunikation", "default": false, "operator": "SBG"}, {"label": "Mass Response Service GmbH", "default": false, "operator": "MASS"}, {"label": "Holding Graz - Kommunale Dienstleistungen GmbH", "default": false, "operator": "HGRAZ"}]}
\.


--
-- Name: setting_options_uid_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.setting_options_uid_seq', 1, true);


--
-- Name: TABLE setting_options; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.setting_options TO qgis;


--
-- PostgreSQL database dump complete
--

