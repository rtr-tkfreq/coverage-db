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
-- Name: cov_layer; Type: TABLE; Schema: public; Owner: postgres
--
-- One row per selectable map layer: a real operator (code matches
-- cov_mno.operator/tileurl.operator directly, e.g. 'TMA') or a combined/
-- derived layer (e.g. '@all', or a specific-reference multi-operator combo).
-- reference is informational/NULL for layers that aren't pinned to one band.

CREATE TABLE public.cov_layer (
    code character varying NOT NULL,
    reference character varying,
    visible_name character varying NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL
);


ALTER TABLE public.cov_layer OWNER TO postgres;

--
-- Name: cov_layer_source; Type: TABLE; Schema: public; Owner: postgres
--
-- Explicit dependency graph for combined layers: one row per (layer, source,
-- reference) edge, meaning "layer includes source's data at this specific
-- reference". `reference` is independent of source's own cov_layer.reference
-- (its canonical/standalone reference) — e.g. A1TA's own listing uses
-- F1/16, but a combined F7/16 layer depending on A1TA needs A1TA's F7/16
-- data specifically, a different reference than A1TA's standalone one. A
-- layer with no rows here is a leaf (rendered directly from cov_mno, using
-- its own cov_layer.reference). Consumed by cov_render_tiles.py (render
-- order/staleness) and api.cov_layer() (point-info resolution) — not
-- exposed via the api schema itself, since the graph structure is an
-- implementation detail, not something the frontend queries directly.
CREATE TABLE public.cov_layer_source (
    layer character varying NOT NULL,
    source character varying NOT NULL,
    reference character varying NOT NULL
);


ALTER TABLE public.cov_layer_source OWNER TO postgres;

--
-- Name: cov_layer_obligation; Type: TABLE; Schema: public; Owner: postgres
--

-- Supply-obligation overlays for a layer, e.g. which cadastral communities
-- (Katastralgemeinden) an operator is obligated to cover by what date.
-- label_de/label_en are real backend-owned localized display text (not
-- derived/guessed) — source: the old setting_options.filter JSON already
-- carried this per obligation, the frontend just never read it and
-- hardcoded its own (slightly different) German/English strings instead.
CREATE TABLE public.cov_layer_obligation (
    layer character varying NOT NULL,
    type character varying NOT NULL,
    label_de character varying NOT NULL,
    label_en character varying NOT NULL,
    source character varying[] NOT NULL
);


ALTER TABLE public.cov_layer_obligation OWNER TO postgres;

--
-- Name: layers; Type: VIEW; Schema: api; Owner: postgres
--

CREATE VIEW api.layers AS
 SELECT cov_layer.code,
    cov_layer.reference,
    cov_layer.visible_name,
    cov_layer.is_default,
    cov_layer.sort_order
   FROM public.cov_layer;


ALTER TABLE api.layers OWNER TO postgres;

--
-- Name: layer_obligations; Type: VIEW; Schema: api; Owner: postgres
--

CREATE VIEW api.layer_obligations AS
 SELECT cov_layer_obligation.layer,
    cov_layer_obligation.type,
    cov_layer_obligation.label_de,
    cov_layer_obligation.label_en,
    cov_layer_obligation.source
   FROM public.cov_layer_obligation;


ALTER TABLE api.layer_obligations OWNER TO postgres;

--
-- Name: cov_layer(double precision, double precision, character varying); Type: FUNCTION; Schema: api; Owner: postgres
--
-- Point-info lookup for a *selected layer* (leaf or combined), replacing
-- per-operator/-reference filtering with resolution through cov_layer_source:
-- a combined layer's rows in cov_layer_source list every (source, reference)
-- it's built from; a leaf with no cov_layer_source rows resolves to itself,
-- using its own cov_layer.reference. This is what lets one function serve
-- "@all" (every operator's canonical reference), a single operator, and a
-- combined layer like an F7/16 combo of several operators uniformly.

CREATE FUNCTION api.cov_layer(cov_longitude double precision, cov_latitude double precision, cov_layer character varying) RETURNS TABLE(operator character varying, reference character varying, license character varying, last_updated character varying, raster character varying, technology character varying, downloadkbitmax integer, uploadkbitmax integer, downloadkbitnormal integer, uploadkbitnormal integer, geojson text, centroid_x double precision, centroid_y double precision)
    LANGUAGE plpgsql
    AS $_$
BEGIN
   RETURN QUERY
   WITH resolved AS (
       SELECT cls.source AS operator, cls.reference AS reference
         FROM public.cov_layer_source cls WHERE cls.layer = cov_layer
       UNION ALL
       SELECT cl.code, cl.reference
         FROM public.cov_layer cl
        WHERE cl.code = cov_layer
          AND NOT EXISTS (SELECT 1 FROM public.cov_layer_source cls2 WHERE cls2.layer = cov_layer)
   )
   SELECT
          coalesce(vn.visible_name, m.operator)::VARCHAR AS operator,
          m.reference::VARCHAR,
          m.license::VARCHAR,
          m.rfc_date::VARCHAR AS last_updated,
          m.raster::VARCHAR,
          NULL::VARCHAR AS technology,
          round(m.dl_max / 1000)::integer AS downloadKbitMax,
          round(m.ul_max / 1000)::integer AS uploadKbitMax,
          round(m.dl_normal / 1000)::integer AS downloadKbitNormal,
          round(m.ul_normal / 1000)::integer AS uploadKbitNormal,
          ST_AsGeoJSON(ST_Transform(m.geom, 4326)) AS geoJson,
          ST_X(ST_Centroid(ST_Transform(m.geom, 4326))),
          ST_Y(ST_Centroid(ST_Transform(m.geom, 4326)))
     FROM public.cov_mno m
     JOIN resolved r ON r.operator = m.operator AND r.reference = m.reference
     LEFT JOIN public.cov_visible_name vn ON vn.operator = m.operator
    WHERE ST_intersects((ST_Transform(ST_SetSRID(ST_MakePoint(cov_longitude::FLOAT, cov_latitude::FLOAT), 4326), 3857)), m.geom)
    ORDER BY m.dl_normal DESC;
END;
$_$;


ALTER FUNCTION api.cov_layer(cov_longitude double precision, cov_latitude double precision, cov_layer character varying) OWNER TO postgres;

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
-- Name: cov_layer cov_layer_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cov_layer
    ADD CONSTRAINT cov_layer_pkey PRIMARY KEY (code);


--
-- Name: cov_layer_source cov_layer_source_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cov_layer_source
    ADD CONSTRAINT cov_layer_source_pkey PRIMARY KEY (layer, source, reference);


--
-- Name: cov_layer_source cov_layer_source_layer_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cov_layer_source
    ADD CONSTRAINT cov_layer_source_layer_fkey FOREIGN KEY (layer) REFERENCES public.cov_layer(code);


--
-- Name: cov_layer_source cov_layer_source_source_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cov_layer_source
    ADD CONSTRAINT cov_layer_source_source_fkey FOREIGN KEY (source) REFERENCES public.cov_layer(code);


--
-- Name: cov_layer_obligation cov_layer_obligation_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cov_layer_obligation
    ADD CONSTRAINT cov_layer_obligation_pkey PRIMARY KEY (layer, type);


--
-- Name: cov_layer_obligation cov_layer_obligation_layer_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.cov_layer_obligation
    ADD CONSTRAINT cov_layer_obligation_layer_fkey FOREIGN KEY (layer) REFERENCES public.cov_layer(code);


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
-- Name: TABLE layers; Type: ACL; Schema: api; Owner: postgres
--

GRANT SELECT ON TABLE api.layers TO web_anon;


--
-- Name: TABLE layer_obligations; Type: ACL; Schema: api; Owner: postgres
--

GRANT SELECT ON TABLE api.layer_obligations TO web_anon;

--
-- Name: FUNCTION cov_layer(double precision, double precision, character varying); Type: ACL; Schema: api; Owner: postgres
--

GRANT EXECUTE ON FUNCTION api.cov_layer(double precision, double precision, character varying) TO web_anon;

-- Plain PL/pgSQL functions run as INVOKER by default (unlike views, which
-- run as their owner) — api.cov_layer()'s body queries these public-schema
-- tables directly, so web_anon needs SELECT on them too, or every call
-- fails with "permission denied for table cov_layer_source" regardless of
-- the EXECUTE grant above. This does NOT expose them as REST resources —
-- PostgREST only serves the `api` schema (db-schema=api), so a grant on a
-- `public` table only lets the function read it on the caller's behalf.
GRANT SELECT ON TABLE public.cov_layer TO web_anon;
GRANT SELECT ON TABLE public.cov_layer_source TO web_anon;

-- cov_layer_obligation has no such requirement: only queried via the
-- api.layer_obligations VIEW, and views run as their owner (postgres) by
-- default, so the view-level grant above is sufficient on its own.
-- cov_render_tiles.py's own reads of cov_layer/cov_layer_source run as the
-- postgres OS user / superuser via peer auth, so need no explicit grant
-- either way.


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

