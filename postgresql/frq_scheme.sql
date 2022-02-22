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
-- Name: api; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA api;


ALTER SCHEMA api OWNER TO postgres;

--
-- Name: topology; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA topology;


ALTER SCHEMA topology OWNER TO postgres;

--
-- Name: SCHEMA topology; Type: COMMENT; Schema: -; Owner: postgres
--

COMMENT ON SCHEMA topology IS 'PostGIS Topology schema';


--
-- Name: postgis; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA public;


--
-- Name: EXTENSION postgis; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION postgis IS 'PostGIS geometry and geography spatial types and functions';


--
-- Name: postgis_raster; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS postgis_raster WITH SCHEMA public;


--
-- Name: EXTENSION postgis_raster; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION postgis_raster IS 'PostGIS raster types and functions';


--
-- Name: postgis_topology; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS postgis_topology WITH SCHEMA topology;


--
-- Name: EXTENSION postgis_topology; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION postgis_topology IS 'PostGIS topology spatial types and functions';


--
-- Name: cov(double precision, double precision); Type: FUNCTION; Schema: api; Owner: qgis
--

CREATE FUNCTION api.cov(cov_longitude double precision, cov_latitude double precision) RETURNS TABLE(operator character varying, reference character varying, license character varying, last_updated character varying, raster character varying, technology character varying, downloadkbitmax integer, uploadkbitmax integer, downloadkbitnormal integer, uploadkbitnormal integer, geojson text, centroid_x double precision, centroid_y double precision)
    LANGUAGE plpgsql
    AS $_$
BEGIN
   return query
   SELECT
          coalesce(vn.visible_name, cov_mno.operator)::VARCHAR as operator,
          public.cov_mno.reference::VARCHAR,
          public.cov_mno.license::VARCHAR,
          public.cov_mno.rfc_date::VARCHAR last_updated,
          public.cov_mno.raster::VARCHAR,
          NULL::VARCHAR,
          round(public.cov_mno.dl_max /1000)::integer downloadKbitMax,
          round(public.cov_mno.ul_max /1000)::integer uploadKbitMax,
          round(public.cov_mno.dl_normal /1000)::integer downloadKbitNormal,
          round(public.cov_mno.ul_normal/1000)::integer uploadKbitNormal,
          ST_AsGeoJSON(ST_Transform(public.atraster.geom,4326)) geoJson,
                  ST_X(ST_Centroid(ST_Transform(public.atraster.geom,4326))),
          ST_Y(ST_Centroid(ST_Transform(public.atraster.geom,4326)))
          from public.atraster
          left join public.cov_mno on public.cov_mno.raster=public.atraster.id
          left join public.cov_visible_name vn on vn.operator = public.cov_mno.operator
          where public.cov_mno.raster is not null AND
                    ST_intersects((ST_Transform(ST_SetSRID(ST_MakePoint($1::FLOAT,$2::FLOAT),4326),3035)),public.atraster.geom)
          order by public.cov_mno.dl_max desc;
END ;
$_$;


ALTER FUNCTION api.cov(cov_longitude double precision, cov_latitude double precision) OWNER TO qgis;

--
-- Name: cov(double precision, double precision, character varying, character varying); Type: FUNCTION; Schema: api; Owner: qgis
--

CREATE FUNCTION api.cov(cov_longitude double precision, cov_latitude double precision, cov_operator character varying, cov_reference character varying) RETURNS TABLE(operator character varying, reference character varying, license character varying, last_updated character varying, raster character varying, technology character varying, downloadkbitmax integer, uploadkbitmax integer, downloadkbitnormal integer, uploadkbitnormal integer, geojson text, centroid_x double precision, centroid_y double precision)
    LANGUAGE plpgsql
    AS $_$
BEGIN
   return query
   SELECT
          coalesce(vn.visible_name, cov_mno.operator)::VARCHAR as operator,
          public.cov_mno.reference::VARCHAR,
          public.cov_mno.license::VARCHAR,
          public.cov_mno.rfc_date::VARCHAR last_updated,
          public.cov_mno.raster::VARCHAR,
          NULL::VARCHAR,
          round(public.cov_mno.dl_max /1000)::integer downloadKbitMax,
          round(public.cov_mno.ul_max /1000)::integer uploadKbitMax,
          round(public.cov_mno.dl_normal /1000)::integer downloadKbitNormal,
          round(public.cov_mno.ul_normal/1000)::integer uploadKbitNormal,
          ST_AsGeoJSON(ST_Transform(public.atraster.geom,4326)) geoJson,
                  ST_X(ST_Centroid(ST_Transform(public.atraster.geom,4326))),
          ST_Y(ST_Centroid(ST_Transform(public.atraster.geom,4326)))
          from public.atraster
          left join public.cov_mno on public.cov_mno.raster=public.atraster.id
          left join public.cov_visible_name vn on vn.operator = public.cov_mno.operator
          where public.cov_mno.raster is not null and
                    -- For geodetic coordinates, X is longitude and Y is latitude
                    ST_intersects((ST_Transform(ST_SetSRID(ST_MakePoint($1::FLOAT,$2::FLOAT),4326),3035)),public.atraster.geom)
                    and coalesce(vn.visible_name, cov_mno.operator)::VARCHAR = cov_operator 
                    and public.cov_mno.reference::VARCHAR = cov_reference
          order by public.cov_mno.dl_max desc;
                    
END ;
$_$;


ALTER FUNCTION api.cov(cov_longitude double precision, cov_latitude double precision, cov_operator character varying, cov_reference character varying) OWNER TO qgis;

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
-- Name: settings; Type: VIEW; Schema: api; Owner: postgres
--

CREATE VIEW api.settings AS
 SELECT setting_options.uid,
    setting_options.object,
    setting_options.filter
   FROM public.setting_options
  WHERE (setting_options.uid = 1);


ALTER TABLE api.settings OWNER TO postgres;

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
-- Name: atraster; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.atraster (
    gid integer NOT NULL,
    id character varying(254),
    name character varying(254),
    geom public.geometry(MultiPolygon,3035)
);


ALTER TABLE public.atraster OWNER TO postgres;

--
-- Name: atraster_gid_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.atraster_gid_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.atraster_gid_seq OWNER TO postgres;

--
-- Name: atraster_gid_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.atraster_gid_seq OWNED BY public.atraster.gid;


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
-- Name: atraster gid; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.atraster ALTER COLUMN gid SET DEFAULT nextval('public.atraster_gid_seq'::regclass);


--
-- Name: cov_mno uid; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cov_mno ALTER COLUMN uid SET DEFAULT nextval('public.cov_mno_uid_seq'::regclass);


--
-- Name: cov_visible_name uid; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cov_visible_name ALTER COLUMN uid SET DEFAULT nextval('public.cov_visible_name_uid_seq'::regclass);


--
-- Name: setting_options uid; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.setting_options ALTER COLUMN uid SET DEFAULT nextval('public.setting_options_uid_seq'::regclass);


--
-- Name: tileurl uid; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.tileurl ALTER COLUMN uid SET DEFAULT nextval('public.tileurl_uid_seq'::regclass);


--
-- Name: atraster atraster_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.atraster
    ADD CONSTRAINT atraster_pkey PRIMARY KEY (gid);


--
-- Name: cov_mno cov_mno_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cov_mno
    ADD CONSTRAINT cov_mno_pkey PRIMARY KEY (uid);


--
-- Name: cov_visible_name cov_visible_name_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cov_visible_name
    ADD CONSTRAINT cov_visible_name_pkey PRIMARY KEY (uid);


--
-- Name: cov_mno operator_reference_raster_rfc_date_id; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cov_mno
    ADD CONSTRAINT operator_reference_raster_rfc_date_id UNIQUE (operator, reference, raster, rfc_date);


--
-- Name: atraster_geom_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX atraster_geom_idx ON public.atraster USING gist (geom);


--
-- Name: cov_mno_operator_reference_license_raster_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX cov_mno_operator_reference_license_raster_idx ON public.cov_mno USING btree (operator, reference, license, raster);


--
-- Name: cov_mno_raster_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX cov_mno_raster_idx ON public.cov_mno USING btree (raster);


--
-- Name: cov_visible_name_visible_name_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX cov_visible_name_visible_name_idx ON public.cov_visible_name USING btree (visible_name);


--
-- Name: idx_cov_mno_raster_dl_normal; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_cov_mno_raster_dl_normal ON public.cov_mno USING btree (raster, dl_normal);


--
-- Name: idx_the_geom_3857_atraster; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_the_geom_3857_atraster ON public.atraster USING gist (public.st_transform(geom, 3857)) WHERE (geom IS NOT NULL);


--
-- Name: SCHEMA api; Type: ACL; Schema: -; Owner: postgres
--

GRANT USAGE ON SCHEMA api TO web_anon;
GRANT ALL ON SCHEMA api TO qgis;


--
-- Name: TABLE setting_options; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.setting_options TO qgis;


--
-- Name: TABLE settings; Type: ACL; Schema: api; Owner: postgres
--

GRANT SELECT ON TABLE api.settings TO web_anon;


--
-- Name: TABLE tileurl; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.tileurl TO qgis;


--
-- Name: TABLE tileurl; Type: ACL; Schema: api; Owner: postgres
--

GRANT SELECT ON TABLE api.tileurl TO web_anon;


--
-- Name: TABLE atraster; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.atraster TO qgis;
GRANT SELECT ON TABLE public.atraster TO web_anon;


--
-- Name: TABLE cov_mno; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.cov_mno TO web_anon;
GRANT ALL ON TABLE public.cov_mno TO qgis;


--
-- Name: TABLE cov_visible_name; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.cov_visible_name TO web_anon;


--
-- Name: SEQUENCE tileurl_uid_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.tileurl_uid_seq TO qgis;


--
-- PostgreSQL database dump complete
--

