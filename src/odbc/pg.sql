--
-- ejabberd, Copyright (C) 2002-2012   ProcessOne
--
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License as
-- published by the Free Software Foundation; either version 2 of the
-- License, or (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
-- General Public License for more details.
--                         
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
-- 02111-1307 USA
--

CREATE TABLE users (
    username text PRIMARY KEY,
    "password" text NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);


CREATE TABLE last (
    username text PRIMARY KEY,
    seconds text NOT NULL,
    state text NOT NULL
);


CREATE TABLE rosterusers (
    username text NOT NULL,
    jid text NOT NULL,
    nick text NOT NULL,
    subscription character(1) NOT NULL,
    ask character(1) NOT NULL,
    askmessage text NOT NULL,
    server character(1) NOT NULL,
    subscribe text,
    "type" text,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX i_rosteru_user_jid ON rosterusers USING btree (username, jid);
CREATE INDEX i_rosteru_username ON rosterusers USING btree (username);
CREATE INDEX i_rosteru_jid ON rosterusers USING btree (jid);


CREATE TABLE rostergroups (
    username text NOT NULL,
    jid text NOT NULL,
    grp text NOT NULL
);

CREATE INDEX pk_rosterg_user_jid ON rostergroups USING btree (username, jid);

CREATE TABLE sr_group (
    name text NOT NULL,
    opts text NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE sr_user (
    jid text NOT NULL,
    grp text NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX i_sr_user_jid_grp ON sr_user USING btree (jid, grp);
CREATE INDEX i_sr_user_jid ON sr_user USING btree (jid);
CREATE INDEX i_sr_user_grp ON sr_user USING btree (grp);

CREATE TABLE spool (
    username text NOT NULL,
    xml text NOT NULL,
    seq SERIAL,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE INDEX i_despool ON spool USING btree (username);


CREATE TABLE vcard (
    username text PRIMARY KEY,
    vcard text NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE vcard_xupdate (
    username text PRIMARY KEY,
    hash text NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE vcard_search (
    username text NOT NULL,
    lusername text PRIMARY KEY,
    fn text NOT NULL,
    lfn text NOT NULL,
    family text NOT NULL,
    lfamily text NOT NULL,
    given text NOT NULL,
    lgiven text NOT NULL,
    middle text NOT NULL,
    lmiddle text NOT NULL,
    nickname text NOT NULL,
    lnickname text NOT NULL,
    bday text NOT NULL,
    lbday text NOT NULL,
    ctry text NOT NULL,
    lctry text NOT NULL,
    locality text NOT NULL,
    llocality text NOT NULL,
    email text NOT NULL,
    lemail text NOT NULL,
    orgname text NOT NULL,
    lorgname text NOT NULL,
    orgunit text NOT NULL,
    lorgunit text NOT NULL
);

CREATE INDEX i_vcard_search_lfn       ON vcard_search(lfn);
CREATE INDEX i_vcard_search_lfamily   ON vcard_search(lfamily);
CREATE INDEX i_vcard_search_lgiven    ON vcard_search(lgiven);
CREATE INDEX i_vcard_search_lmiddle   ON vcard_search(lmiddle);
CREATE INDEX i_vcard_search_lnickname ON vcard_search(lnickname);
CREATE INDEX i_vcard_search_lbday     ON vcard_search(lbday);
CREATE INDEX i_vcard_search_lctry     ON vcard_search(lctry);
CREATE INDEX i_vcard_search_llocality ON vcard_search(llocality);
CREATE INDEX i_vcard_search_lemail    ON vcard_search(lemail);
CREATE INDEX i_vcard_search_lorgname  ON vcard_search(lorgname);
CREATE INDEX i_vcard_search_lorgunit  ON vcard_search(lorgunit);

CREATE TABLE privacy_default_list (
    username text PRIMARY KEY,
    name text NOT NULL
);

CREATE TABLE privacy_list (
    username text NOT NULL,
    name text NOT NULL,
    id SERIAL UNIQUE,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE INDEX i_privacy_list_username ON privacy_list USING btree (username);
CREATE UNIQUE INDEX i_privacy_list_username_name ON privacy_list USING btree (username, name);

CREATE TABLE privacy_list_data (
    id bigint REFERENCES privacy_list(id) ON DELETE CASCADE,
    t character(1) NOT NULL,
    value text NOT NULL,
    action character(1) NOT NULL,
    ord NUMERIC NOT NULL,
    match_all boolean NOT NULL,
    match_iq boolean NOT NULL,
    match_message boolean NOT NULL,
    match_presence_in boolean NOT NULL,
    match_presence_out boolean NOT NULL
);

CREATE TABLE private_storage (
    username text NOT NULL,
    namespace text NOT NULL,
    data text NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE INDEX i_private_storage_username ON private_storage USING btree (username);
CREATE UNIQUE INDEX i_private_storage_username_namespace ON private_storage USING btree (username, namespace);


CREATE TABLE roster_version (
    username text PRIMARY KEY,
    version text NOT NULL
);

-- To update from 0.9.8:
-- CREATE SEQUENCE spool_seq_seq;
-- ALTER TABLE spool ADD COLUMN seq integer;
-- ALTER TABLE spool ALTER COLUMN seq SET DEFAULT nextval('spool_seq_seq');
-- UPDATE spool SET seq = DEFAULT;
-- ALTER TABLE spool ALTER COLUMN seq SET NOT NULL;

-- To update from 1.x:
-- ALTER TABLE rosterusers ADD COLUMN askmessage text;
-- UPDATE rosterusers SET askmessage = '';
-- ALTER TABLE rosterusers ALTER COLUMN askmessage SET NOT NULL;

CREATE TABLE pubsub_node (
  host text,
  node text,
  parent text,
  "type" text,
  nodeid SERIAL UNIQUE
);
CREATE INDEX i_pubsub_node_parent ON pubsub_node USING btree (parent);
CREATE UNIQUE INDEX i_pubsub_node_tuple ON pubsub_node USING btree (host, node);

CREATE TABLE pubsub_node_option (
  nodeid bigint REFERENCES pubsub_node(nodeid) ON DELETE CASCADE,
  name text,
  val text
);
CREATE INDEX i_pubsub_node_option_nodeid ON pubsub_node_option USING btree (nodeid);

CREATE TABLE pubsub_node_owner (
  nodeid bigint REFERENCES pubsub_node(nodeid) ON DELETE CASCADE,
  owner text
);
CREATE INDEX i_pubsub_node_owner_nodeid ON pubsub_node_owner USING btree (nodeid);

CREATE TABLE pubsub_state (
  nodeid bigint REFERENCES pubsub_node(nodeid) ON DELETE CASCADE,
  jid text,
  affiliation character(1),
  subscriptions text,
  stateid SERIAL UNIQUE
);
CREATE INDEX i_pubsub_state_jid ON pubsub_state USING btree (jid);
CREATE UNIQUE INDEX i_pubsub_state_tuple ON pubsub_state USING btree (nodeid, jid);

CREATE TABLE pubsub_item (
  nodeid bigint REFERENCES pubsub_node(nodeid) ON DELETE CASCADE,
  itemid text, 
  publisher text,
  creation text,
  modification text,
  payload text
);
CREATE INDEX i_pubsub_item_itemid ON pubsub_item USING btree (itemid);
CREATE UNIQUE INDEX i_pubsub_item_tuple ON pubsub_item USING btree (nodeid, itemid);

CREATE TABLE pubsub_subscription_opt (
  subid text,
  opt_name varchar(32),
  opt_value text
);
CREATE UNIQUE INDEX i_pubsub_subscription_opt ON pubsub_subscription_opt USING btree (subid, opt_name);

CREATE TABLE muc_room (
    name text NOT NULL,
    host text NOT NULL,
    opts text NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX i_muc_room_name_host ON muc_room USING btree (name, host);

CREATE TABLE muc_registered (
    jid text NOT NULL,
    host text NOT NULL,
    nick text NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE INDEX i_muc_registered_nick ON muc_registered USING btree (nick);
CREATE UNIQUE INDEX i_muc_registered_jid_host ON muc_registered USING btree (jid, host);

CREATE TABLE irc_custom (
    jid text NOT NULL,
    host text NOT NULL,
    data text NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX i_irc_custom_jid_host ON irc_custom USING btree (jid, host);

CREATE TABLE motd (
    username text PRIMARY KEY,
    xml text,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);
