// Browser side of src/net.rs: websocket + HTTP POST for the lockstep demo.
// Loaded after gl.js and sapp_jsutils.js (they provide miniquad_add_plugin,
// js_object and consume_js_object).
"use strict";

var lsn_socket = null;
var lsn_state = 0; // 0 connecting, 1 open, 2 closed
var lsn_close_reason = "";
var lsn_inbox = [];
var lsn_requests = {};
var lsn_next_id = 0;

function lsn_register(importObject) {
    importObject.env.lsn_ws_connect = function (url) {
        lsn_state = 0;
        lsn_close_reason = "";
        lsn_inbox = [];
        try {
            lsn_socket = new WebSocket(consume_js_object(url));
        } catch (e) {
            lsn_state = 2;
            lsn_close_reason = "websocket connect failed: " + e;
            return;
        }
        lsn_socket.onopen = function () { lsn_state = 1; };
        lsn_socket.onmessage = function (m) {
            if (typeof m.data === "string") lsn_inbox.push(m.data);
        };
        lsn_socket.onerror = function () {
            if (!lsn_close_reason) lsn_close_reason = "connection error";
        };
        lsn_socket.onclose = function (e) {
            lsn_state = 2;
            if (!lsn_close_reason) {
                lsn_close_reason = e.reason || ("connection closed (code " + e.code + ")");
            }
        };
    };

    importObject.env.lsn_ws_send = function (text) {
        var s = consume_js_object(text);
        if (lsn_socket && lsn_state === 1) lsn_socket.send(s);
    };

    importObject.env.lsn_ws_try_recv = function () {
        return lsn_inbox.length ? js_object(lsn_inbox.shift()) : -1;
    };

    importObject.env.lsn_ws_state = function () { return lsn_state; };

    importObject.env.lsn_ws_close_reason = function () { return js_object(lsn_close_reason); };

    importObject.env.lsn_http_post = function (url) {
        var id = lsn_next_id++;
        var req = { status: 0, body: "" };
        lsn_requests[id] = req;
        var xhr = new XMLHttpRequest();
        xhr.open("POST", consume_js_object(url));
        xhr.onload = function () {
            if (xhr.status === 200) {
                req.status = 1;
                req.body = xhr.responseText;
            } else {
                req.status = 2;
                req.body = "server replied HTTP " + xhr.status;
            }
        };
        xhr.onerror = function () {
            req.status = 2;
            req.body = "request failed (is the server running?)";
        };
        xhr.send();
        return id;
    };

    importObject.env.lsn_http_status = function (id) {
        return lsn_requests[id] ? lsn_requests[id].status : 2;
    };

    importObject.env.lsn_http_body = function (id) {
        var req = lsn_requests[id];
        delete lsn_requests[id];
        return js_object(req ? req.body : "");
    };

    importObject.env.lsn_page_param = function (name) {
        var v = new URLSearchParams(window.location.search).get(consume_js_object(name));
        return js_object(v || "");
    };

    importObject.env.lsn_default_server = function () {
        var scheme = window.location.protocol === "https:" ? "https://" : "http://";
        return js_object(scheme + (window.location.hostname || "localhost") + ":8080");
    };
}

miniquad_add_plugin({ register_plugin: lsn_register, version: 1, name: "lockstep_net" });
