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
-- Name: cov_mno; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.cov_mno (
    uid integer NOT NULL,
    operator character varying(50),
    reference character varying(50),
    license character varying(50),
    rfc_date character varying(50),
    raster character varying(50),
    dl_normal bigint,
    ul_normal bigint,
    dl_max bigint,
    ul_max bigint
);


ALTER TABLE public.cov_mno OWNER TO postgres;

--
-- Name: cov_mno_uid_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.cov_mno_uid_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.cov_mno_uid_seq OWNER TO postgres;

--
-- Name: cov_mno_uid_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.cov_mno_uid_seq OWNED BY public.cov_mno.uid;


--
-- Name: cov_mno uid; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cov_mno ALTER COLUMN uid SET DEFAULT nextval('public.cov_mno_uid_seq'::regclass);


--
-- Name: cov_mno cov_mno_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cov_mno
    ADD CONSTRAINT cov_mno_pkey PRIMARY KEY (uid);


--
-- Name: cov_mno operator_reference_raster_rfc_date_id; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cov_mno
    ADD CONSTRAINT operator_reference_raster_rfc_date_id UNIQUE (operator, reference, raster, rfc_date);


--
-- Name: cov_mno_operator_reference_license_raster_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX cov_mno_operator_reference_license_raster_idx ON public.cov_mno USING btree (operator, reference, license, raster);


--
-- Name: cov_mno_raster_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX cov_mno_raster_idx ON public.cov_mno USING btree (raster);


--
-- Name: idx_cov_mno_raster_dl_normal; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_cov_mno_raster_dl_normal ON public.cov_mno USING btree (raster, dl_normal);


--
-- Name: TABLE cov_mno; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.cov_mno TO web_anon;
GRANT ALL ON TABLE public.cov_mno TO qgis;


--
-- PostgreSQL database dump complete
--

