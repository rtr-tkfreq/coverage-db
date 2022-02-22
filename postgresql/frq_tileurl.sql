--
-- PostgreSQL database dump
--

-- Dumped from database version 13.3 (Debian 13.3-1.pgdg100+1)
-- Dumped by pg_dump version 13.3 (Debian 13.3-1.pgdg100+1)

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
-- Name: tileurl; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.tileurl (
    uid integer NOT NULL,
    operator character varying,
    reference character varying,
    date date,
    url character varying
);


ALTER TABLE public.tileurl OWNER TO postgres;

--
-- Name: tileurl_uid_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.tileurl_uid_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.tileurl_uid_seq OWNER TO postgres;

--
-- Name: tileurl_uid_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.tileurl_uid_seq OWNED BY public.tileurl.uid;


--
-- Name: tileurl uid; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.tileurl ALTER COLUMN uid SET DEFAULT nextval('public.tileurl_uid_seq'::regclass);


--
-- Data for Name: tileurl; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.tileurl (uid, operator, reference, date, url) FROM stdin;
1	A1TA	F7/16	2021-03-31	/cov/A1TA/F7_16/2021-03-31
2	TMA	F7/16	2021-04-01	/cov/TMA/F7_16/2021-04-01
3	H3A	F7/16	2021-05-05	/cov/H3A/F7_16/2021-05-05
\.


--
-- Name: tileurl_uid_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.tileurl_uid_seq', 4, true);


--
-- PostgreSQL database dump complete
--

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

--
-- Name: tileurl; Type: VIEW; Schema: api; Owner: postgres
--

CREATE VIEW api.tileurl AS
 SELECT tileurl.operator,
    tileurl.reference,
    tileurl.date,
    tileurl.url
   FROM public.tileurl;


ALTER TABLE api.tileurl OWNER TO postgres;

--
-- Name: TABLE tileurl; Type: ACL; Schema: api; Owner: postgres
--

GRANT SELECT ON TABLE api.tileurl TO web_anon;


--
-- PostgreSQL database dump complete
--

