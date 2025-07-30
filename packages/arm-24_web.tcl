# armour/packages/arm-24_web.tcl - An enhanced, self-contained web interface for Armour
# This version includes persistent sessions, a template engine, bulk actions, and AJAX.

namespace eval ::arm::web {

    variable items_per_page 25

    # Asynchronous Caching for dashboard stats
    variable wcount_cache 0
    variable bcount_cache 0
    ## FIX: Added optional arguments to accept parameters from the cron job without error.
    proc update_list_counts {{minute ""} {hour ""} {day ""} {month ""} {weekday ""}} { variable wcount_cache; variable bcount_cache; set wcount_cache [dict size [dict filter $::arm::entries script {id data} {expr {[dict get $data type] eq "white"}}]]; set bcount_cache [dict size [dict filter $::arm::entries script {id data} {expr {[dict get $data type] eq "black"}}]]; ::arm::debug 4 "\[@\] Armour Web: Updated list counts cache (W: $wcount_cache, B: $bcount_cache)." }
    bind cron - "*/5 * * * *" {::arm::coroexec ::arm::web::update_list_counts}
    ::arm::coroexec ::arm::web::update_list_counts

    variable templates [dict create]
    proc define_template {name content} {
        variable templates
        dict set templates $name $content
    }

    # --- TEMPLATE DEFINITIONS ---
    define_template "layout" {<!DOCTYPE html><html><head><title>Armour - %%TITLE%%</title><link rel="stylesheet" href="https://unpkg.com/simpledotcss/simple.min.css"><style>button.tertiary{background-color:transparent;border:1px solid var(--border);color:var(--text);} button.danger{background-color:#c82333;border-color:#c82333;} .flash{padding:1em;margin-bottom:1em;border-radius:var(--border-radius);}.flash.success{background-color:#d4edda;color:#155724;}.flash.error{background-color:#f8d7da;color:#721c24;}</style>%%JAVASCRIPT%%</head><body><main>%%NAVIGATION%%%%FLASH_MESSAGE%%%%BODY%%</main></body></html>}
    define_template "navigation" {<nav><a href="/">Dashboard</a> | <a href="/lists">Lists</a> | <a href="/users">Users</a> | <a href="/channels">Channels</a> | <a href="/events">Events</a> | <a href="/logout">Logout</a></nav><hr>}
    define_template "login_page" {<h1>Armour Login</h1>%%ERROR%%<form method='POST' action='/login'><label>Username</label><input type='text' name='username' required><label>Password</label><input type='password' name='password' required><button type='submit'>Login</button></form>}
    define_template "dashboard_page" {<h1>Dashboard</h1><div class='grid'><article><h4>Bot Status</h4><ul><li><b>Bot Name:</b> %%BOT_NAME%%</li><li><b>Eggdrop Version:</b> %%EGG_VERSION%%</li><li><b>Armour Version:</b> %%ARMOUR_VERSION%%</li><li><b>Uptime:</b> %%UPTIME%%</li></ul></article><article><h4>Database Stats</h4><ul><li><b>Registered Users:</b> %%USERS_COUNT%%</li><li><b>Managed Channels:</b> %%CHANNELS_COUNT%%</li><li><b>Whitelist Entries:</b> %%WHITE_COUNT%%</li><li><b>Blacklist Entries:</b> %%BLACK_COUNT%%</li></ul></article></div>}
    define_template "js_generic" {<script>function filterTable(i,t){let e,n,l,a,d,r,c,s;for(e=document.getElementById(i),n=e.value.toUpperCase(),l=document.getElementById(t),a=l.getElementsByTagName("tr"),r=1;r<a.length;r++){let i=!1;for(d=a[r].getElementsByTagName("td"),c=0;c<d.length;c++)if(d[c]&&(s=d[c].textContent||d[c].innerText,s.toUpperCase().indexOf(n)>-1)){i=!0;break}i?a[r].style.display="":a[r].style.display="none"}}</script>}
    define_template "js_lists_page" {<script>function checkAll(source, listName) {let checkboxes = document.querySelectorAll('input[name="' + listName + '"]'); for(let i=0; i < checkboxes.length; i++) {checkboxes[i].checked = source.checked;}} function removeEntry(buttonElement, entryId) {if (!confirm('Are you sure you want to remove entry #' + entryId + '?')) { return; } fetch('/api/remove-entry', {method: 'POST', headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'}, body: 'id=' + encodeURIComponent(entryId)}).then(response => response.json()).then(data => {if (data.status === 'success') {let row = buttonElement.closest('tr'); row.style.transition = 'opacity 0.5s'; row.style.opacity = '0'; setTimeout(() => row.remove(), 500);} else {alert('Error: ' + data.message);}});}</script>}
    define_template "lists_page_body" {<h1>Manage Lists</h1><input type='text' id='listFilterInput' onkeyup="filterTable('listFilterInput', 'whitelistTable'); filterTable('listFilterInput', 'blacklistTable');" placeholder='Filter lists by any value...'><fieldset><legend><h2>Add New Entry</h2></legend><form action="/add-entry" method="POST"><input type="hidden" name="csrf_token" value="%%CSRF_TOKEN%%"><div class="grid"><label for="list">List Type<select id="list" name="list" required><option value="white">Whitelist</option><option value="black">Blacklist</option></select></label><label for="chan">Channel<input type="text" id="chan" name="chan" value="*" required></label></div><div class="grid"><label for="method">Method<select id="method" name="method" required><option value="user">user</option><option value="host">host</option><option value="regex">regex</option><option value="text">text</option><option value="country">country</option><option value="asn">asn</option><option value="chan">chan</option></select></label><label for="action">Action<select id="action" name="action" required><option value="A">Accept</option><option value="V">Voice</option><option value="O">Op</option><option value="B">Kickban</option></select></label></div><label for="value">Value</label><input type="text" id="value" name="value" required><label for="reason">Reason</label><input type="text" id="reason" name="reason" required><button type="submit">Add Entry</button></form></fieldset><form action="/bulk-remove-entry" method="POST" onsubmit="return confirm('Are you sure you want to delete all selected entries?');"><input type="hidden" name="csrf_token" value="%%CSRF_TOKEN%%"><h2>Whitelist</h2>%%WHITELIST_PAGINATION%%<table id='whitelistTable'><thead><tr><th><input type="checkbox" onclick="checkAll(this, 'ids')"></th><th>ID</th><th>Chan</th><th>Method</th><th>Value</th><th>Action</th><th>Reason</th><th></th></tr></thead><tbody>%%WHITELIST_ROWS%%</tbody></table>%%WHITELIST_PAGINATION%%<h2>Blacklist</h2>%%BLACKLIST_PAGINATION%%<table id='blacklistTable'><thead><tr><th><input type="checkbox" onclick="checkAll(this, 'ids')"></th><th>ID</th><th>Chan</th><th>Method</th><th>Value</th><th>Action</th><th>Reason</th><th></th></tr></thead><tbody>%%BLACKLIST_ROWS%%</tbody></table>%%BLACKLIST_PAGINATION%%<button type="submit" class="danger">Delete Selected</button></form>}

    # --- CORE SERVER & UTILITY PROCEDURES ---
    proc start_server {} { if {![::arm::cfg:get web:enable]} { return }; set port [::arm::cfg:get web:port]; set bind_ip [::arm::cfg:get web:bind]; if {$bind_ip eq ""} { set bind_ip "0.0.0.0" }; if {[catch {socket -server ::arm::web::accept -myaddr $bind_ip $port} sock]} { ::arm::debug 0 "\[@\] Armour: \x0304(error)\x03 Could not open server socket on $bind_ip port $port. Error: $sock"; return }; ::arm::debug 0 "\[@\] Armour: Starting web interface on $bind_ip port $port" }
    proc url_decode {str} { regsub -all {\+} $str { } str; while {[regexp -indices -- {%([0-9a-fA-F]{2})} $str match]} { set hex [string range $str [expr {[lindex $match 0] + 1}] [lindex $match 1]]; scan $hex %x char_code; set str [string replace $str [lindex $match 0] [lindex $match 1] [format %c $char_code]] }; return $str }
    proc html_escape {str} { return [string map {& &amp; < &lt; > &gt; \" &quot;} $str] }
    proc redirect {sock location} { puts $sock "HTTP/1.0 302 Found\r\nLocation: $location\r\n\r\n" }
    proc parse_form_data {post_data} { set form_data [dict create]; foreach pair [split $post_data &] { lassign [split $pair =] key value; dict set form_data [url_decode $key] [url_decode $value] }; return $form_data }

    proc render_template {template_name data_dict} {
        variable templates
        if {![dict exists $templates $template_name]} { return "" }
        set content [dict get $templates $template_name]
        foreach key [dict keys $data_dict] {
            set value [dict get $data_dict $key]
            regsub -all "%%[string toupper $key]%%" $content $value content
        }
        return $content
    }

    proc render_page {title body {js_template_name ""} {flash_message ""}} {
        set page_data [dict create title $title body $body]
        dict set page_data javascript [render_template $js_template_name [dict create]]
        dict set page_data navigation [expr {$title ne "Login" ? [render_template "navigation" [dict create]] : ""}]
        dict set page_data flash_message $flash_message
        return [render_template "layout" $page_data]
    }

    proc send_http_response {sock html {status "200 OK"}} {
        puts $sock "HTTP/1.0 $status\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: [string length $html]\r\n\r\n$html"
    }
    
    proc get_flash_message {query_params} {
        if {[dict exists $query_params flash_msg]} {
            lassign [split [dict get $query_params flash_msg] ":"] type msg
            return "<div class='flash $type'>[html_escape [regsub -all {\+} $msg { }]]</div>"
        }
        return ""
    }

    proc render_pagination {path current_page total_items} { variable items_per_page; if {$total_items <= $items_per_page} { return "" }; set total_pages [expr {ceil(double($total_items) / $items_per_page)}]; set pagination_html "<div class='pagination' style='text-align:center; margin-top: 1em;'>"; if {$current_page > 1} { append pagination_html "<a href='$path?page=[expr {$current_page - 1}]'>&laquo; Previous</a>" }; append pagination_html " <span style='margin: 0 1em;'>Page $current_page of $total_pages</span> "; if {$current_page < $total_pages} { append pagination_html "<a href='$path?page=[expr {$current_page + 1}]'>Next &raquo;</a>" }; append pagination_html "</div>"; return $pagination_html }
    proc can_admin_modify_target {admin_uid target_uid} { ::arm::db:connect; set admin_levels [::arm::db:query "SELECT level FROM levels WHERE uid=$admin_uid"]; set admin_max_level 0; foreach level_row $admin_levels { if {[lindex $level_row 0] > $admin_max_level} { set admin_max_level [lindex $level_row 0] } }; set target_levels [::arm::db:query "SELECT level FROM levels WHERE uid=$target_uid"]; set target_max_level 0; foreach level_row $target_levels { if {[lindex $level_row 0] > $target_max_level} { set target_max_level [lindex $level_row 0] } }; ::arm::db:close; if {$admin_max_level == 500} { return 1 }; if {$admin_max_level > $target_max_level} { return 1 }; return 0 }

    proc accept {sock addr p} {
        fconfigure $sock -buffering line -translation lf
        if {[eof $sock] || [catch {gets $sock request_line}]} { catch {close $sock}; return }
        set headers [dict create]
        while {[gets $sock line] > 0 && $line ne "\r"} {
            if {[regexp {^([^:]+): (.*)} $line -> key value]} { dict set headers [string trim $key] [string trim $value] }
        }
        lassign $request_line method request_uri version

        set query_params [dict create]
        if {[string first "?" $request_uri] != -1} {
            lassign [split $request_uri "?"] path query_string
            foreach pair [split $query_string &] {
                lassign [split $pair =] key value
                dict set query_params [url_decode $key] [url_decode $value]
            }
        } else {
            set path $request_uri
        }
        set page 1
        if {[dict exists $query_params page]} {
            set page_val [dict get $query_params page]
            if {[string is integer -strict $page_val] && $page_val > 0} { set page $page_val }
        }

        set session [dict create user "" id "" token ""]
        if {[dict exists $headers Cookie]} {
            set cookie_str [dict get $headers Cookie]
            if {[regexp {session_id=([^; ]+)} $cookie_str -> session_id]} {
                set session [verify_session $session_id]
            }
        }

        set post_data ""
        if {$method eq "POST"} {
            set content_length 0
            if {[dict exists $headers "Content-Length"]} { set content_length [dict get $headers "Content-Length"] }
            if {$content_length > 0} { set post_data [read $sock $content_length] }
        }

        if {[dict get $session user] eq ""} {
            if {$path eq "/login"} {
                if {$method eq "POST"} {
                    process_login $sock $post_data
                } else {
                    set login_body [render_template "login_page" [dict create error ""]]
                    send_http_response $sock [render_page "Login" $login_body]
                }
            } else {
                redirect $sock "/login"
            }
        } else {
            set csrf_token [dict get $session token]
            if {$method eq "POST"} {
                set form_data [parse_form_data $post_data]
                if {![dict exists $form_data csrf_token] || [dict get $form_data csrf_token] ne $csrf_token} {
                    set error_body "<h2>403 Forbidden</h2><p>Invalid security token (CSRF check failed).</p>"
                    send_http_response $sock [render_page "Error" $error_body "403 Forbidden"]
                    close $sock; return
                }
            }
            switch -exact -- $path {
                "/" { send_http_response $sock [render_page "Dashboard" [dashboard_page $query_params] "js_generic" [get_flash_message $query_params]] }
                "/lists" { send_http_response $sock [render_page "Manage Lists" [lists_page $page $query_params $csrf_token] "js_lists_page" [get_flash_message $query_params]] }
                "/users" { send_http_response $sock [render_page "Manage Users" [users_page $page $query_params $csrf_token] "js_generic" [get_flash_message $query_params]] }
                "/channels" { send_http_response $sock [render_page "Manage Channels" [channels_page $query_params $csrf_token] "js_generic" [get_flash_message $query_params]] }
                "/events" { send_http_response $sock [render_page "Recent Events" [events_page $page $query_params] "js_generic" [get_flash_message $query_params]] }
                "/login" { redirect $sock "/" }
                "/logout" { logout_handler $sock [dict get $session id] }
                "/add-entry" { if {$method eq "POST"} { process_add_entry $sock $post_data [dict get $session user] } else { redirect $sock "/lists" } }
                "/bulk-remove-entry" { if {$method eq "POST"} { process_bulk_remove_entry $sock $post_data } else { redirect $sock "/lists" } }
                "/update-channel" { if {$method eq "POST"} { process_update_channel $sock $post_data } else { redirect $sock "/channels" } }
                "/update-user" { if {$method eq "POST"} { process_update_user $sock $post_data [dict get $session user] } else { redirect $sock "/users" } }
                "/reset-password" { if {$method eq "POST"} { process_reset_password $sock $post_data [dict get $session user] } else { redirect $sock "/users" } }
                "/delete-user" { if {$method eq "POST"} { process_delete_user $sock $post_data [dict get $session user] } else { redirect $sock "/users" } }
                "/api/remove-entry" { if {$method eq "POST"} { process_api_remove_entry $sock $post_data } }
                default {
                    set notfound_body "<h2>404 Not Found</h2>"
                    send_http_response $sock [render_page "Not Found" $notfound_body] "404 Not Found"
                }
            }
        }
        if {![catch {eof $sock}]} { if {![eof $sock]} { flush $sock } }
        catch {close $sock}
    }

    # --- SESSION MANAGEMENT (Persistent) ---
    proc cleanup_sessions {} { ::arm::db:connect; ::arm::db:query "DELETE FROM web_sessions WHERE expires_ts < [clock seconds]"; ::arm::db:close }
    proc verify_session {session_id} { ::arm::db:connect; set session_row [::arm::db:query "SELECT user FROM web_sessions WHERE session_id='[::arm::db:escape $session_id]' AND expires_ts > [clock seconds]"]; ::arm::db:close; if {[llength $session_row] > 0} { set user [lindex $session_row 0 0]; if {[::arm::userdb:get:level $user *] < [::arm::cfg:get web:level]} { return [dict create user "" id "" token ""] } else { return [dict create user $user id $session_id token [::sha1::sha1 -hex "$session_id$user"]] } } else { return [dict create user "" id "" token ""] } }
    proc process_login {sock post_data} { set form_data [parse_form_data $post_data]; set username ""; set password ""; if {[dict exists $form_data username]} {set username [dict get $form_data username]}; if {[dict exists $form_data password]} {set password [dict get $form_data password]}; set authenticated 0; if {$username ne "" && $password ne ""} {foreach {uid udata} $::arm::dbusers {if {[string equal -nocase [dict get $udata user] $username]} {if {[dict get $udata pass] eq [::arm::userdb:encrypt $password]} {set authenticated 1}; break}}}; if {$authenticated && [::arm::userdb:get:level $username *] >= [::arm::cfg:get web:level]} { set session_id [::sha1::sha1 -hex "[clock clicks][clock seconds][expr {rand()}]"]; set expires [expr {[clock seconds] + 86400}]; ::arm::db:connect; ::arm::db:query "INSERT INTO web_sessions (session_id, user, expires_ts) VALUES ('$session_id', '[::arm::db:escape $username]', $expires)"; ::arm::db:close; puts $sock "HTTP/1.0 302 Found\r\nSet-Cookie: session_id=$session_id; Path=/; HttpOnly; SameSite=Strict\r\nLocation: /\r\n\r\n" } else { set error_body [render_template "login_page" [dict create error "<p style='color:red;'>Invalid credentials or insufficient access level.</p>"]]; send_http_response $sock [render_page "Login" $error_body] } }
    proc logout_handler {sock session_id} { ::arm::db:connect; ::arm::db:query "DELETE FROM web_sessions WHERE session_id='[::arm::db:escape $session_id]'"; ::arm::db:close; puts $sock "HTTP/1.0 302 Found\r\nSet-Cookie: session_id=deleted; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT\r\nLocation: /login\r\n\r\n" }
    
    # --- ACTION HANDLERS ---
    proc process_add_entry {sock post_data user} {set form_data [parse_form_data $post_data]; ::arm::db:add [string toupper [string index [dict get $form_data list] 0]] [dict get $form_data chan] [dict get $form_data method] [dict get $form_data value] "$user (web)" [dict get $form_data action] "1:1:1" [dict get $form_data reason]; redirect $sock "/lists?flash_msg=success:Entry+added+successfully."}
    proc process_bulk_remove_entry {sock post_data} { set ids_to_remove [list]; foreach pair [split $post_data &] {lassign [split $pair =] key id; if {$key eq "ids"} {lappend ids_to_remove [url_decode $id]}}; foreach entry_id $ids_to_remove {::arm::db:rem $entry_id}; redirect $sock "/lists?flash_msg=success:Removed+[llength $ids_to_remove]+entries." }
    proc process_api_remove_entry {sock post_data} { lassign [split $post_data =] key id; ::arm::db:rem [url_decode $id]; set response_json {{"status": "success"}}; puts $sock "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nContent-Length: [string length $response_json]\r\n\r\n$response_json" }
    proc process_delete_user {sock post_data admin_user} { set form_data [parse_form_data $post_data]; set target_uid [dict get $form_data uid]; set admin_uid [::arm::db:get id users user $admin_user]; if {![can_admin_modify_target $admin_uid $target_uid]} { redirect $sock "/users?flash_msg=error:Access+Denied"; return }; set target_user [::arm::db:get user users id $target_uid]; ::arm::userdb:deluser $target_user $target_uid; redirect $sock "/users?flash_msg=success:User+$target_user+deleted." }
    proc process_reset_password {sock post_data admin_user} { set form_data [parse_form_data $post_data]; set target_uid [dict get $form_data uid]; set admin_uid [::arm::db:get id users user $admin_user]; if {![can_admin_modify_target $admin_uid $target_uid]} { redirect $sock "/users?flash_msg=error:Access+Denied"; return }; set new_pass [::arm::randpass]; set enc_pass [::arm::userdb:encrypt $new_pass]; set target_user [::arm::db:get user users id $target_uid]; ::arm::userdb:user:set pass $enc_pass id $target_uid; set note "Password for user '$target_user' (UID: $target_uid) has been reset. New password is: $new_pass"; ::arm::db:connect; ::arm::db:query "INSERT INTO notes (timestamp, from_u, from_id, to_u, to_id, read, note) VALUES ('[clock seconds]', 'Armour', '0', '$admin_user', '$admin_uid', 'N', '[::arm::db:escape $note]')"; ::arm::db:close; redirect $sock "/users?flash_msg=success:Password+reset.+A+note+has+been+sent+to+you." }
    proc process_update_channel {sock post_data} { set form_data [dict create]; foreach pair [split $post_data &] {lassign [split $pair =] key value; dict set form_data [url_decode $key] [url_decode $value]}; if {[dict exists $form_data "kicklock_kicks"]} { set kl_kicks [dict get $form_data "kicklock_kicks"]; set kl_mins [dict get $form_data "kicklock_mins"]; set kl_modes [dict get $form_data "kicklock_modes"]; set kl_duration [dict get $form_data "kicklock_duration"]; dict unset form_data "kicklock_kicks"; dict unset form_data "kicklock_mins"; dict unset form_data "kicklock_modes"; dict unset form_data "kicklock_duration"; if {$kl_kicks ne "" && $kl_mins ne "" && $kl_modes ne "" && $kl_duration ne ""} { if {![string match "+*" $kl_modes]} { set kl_modes "+$kl_modes" }; set assembled_kicklock "${kl_kicks}:${kl_mins}:${kl_modes}:${kl_duration}"; dict set form_data "kicklock" $assembled_kicklock } else { dict set form_data "kicklock" "off" } }; set cid [dict get $form_data cid]; ::arm::db:connect; foreach setting [dict keys $form_data] { set value [dict get $form_data $setting]; if {$setting eq "cid"} continue; set existing_value [lindex [::arm::db:query "SELECT value FROM settings WHERE cid='$cid' AND setting='[::arm::db:escape $setting]'"] 0]; if {$existing_value eq ""} { if {$value ne ""} { ::arm::db:query "INSERT INTO settings (cid, setting, value) VALUES ('$cid', '[::arm::db:escape $setting]', '[::arm::db:escape $value]')" } } else { if {$value eq "" || $value eq "off"} { ::arm::db:query "DELETE FROM settings WHERE cid='$cid' AND setting='[::arm::db:escape $setting]'" } else { ::arm::db:query "UPDATE settings SET value='[::arm::db:escape $value]' WHERE cid='$cid' AND setting='[::arm::db:escape $setting]'" } } dict set $::arm::dbchans $cid $setting $value }; ::arm::db:close; redirect $sock "/channels?flash_msg=success:Channel+settings+updated." }
    proc process_update_user {sock post_data admin_user} { set form_data [parse_form_data $post_data]; set target_uid [dict get $form_data uid]; set admin_uid [::arm::db:get id users user $admin_user]; if {![can_admin_modify_target $admin_uid $target_uid]} { redirect $sock "/users?flash_msg=error:Access+Denied"; return }; ::arm::db:connect; ::arm::db:query "UPDATE users SET email='[::arm::db:escape [dict get $form_data email]]', languages='[::arm::db:escape [dict get $form_data languages]]' WHERE id=$target_uid"; foreach key [dict keys $form_data] { if {[string match "greet_*" $key]} { set cid [lindex [split $key "_"] 1]; set greet_val [::arm::db:escape [dict get $form_data $key]]; set exists [lindex [::arm::db:query "SELECT greet FROM greets WHERE uid=$target_uid AND cid=$cid"] 0]; if {$exists eq ""} { if {$greet_val ne ""} { ::arm::db:query "INSERT INTO greets (cid, uid, greet) VALUES ($cid, $target_uid, '$greet_val')" } } else { if {$greet_val eq ""} { ::arm::db:query "DELETE FROM greets WHERE uid=$target_uid AND cid=$cid" } else { ::arm::db:query "UPDATE greets SET greet='$greet_val' WHERE uid=$target_uid AND cid=$cid" } } } }; ::arm::db:close; redirect $sock "/users?flash_msg=success:User+settings+updated." }
    
    # --- PAGE GENERATORS ---
    proc dashboard_page {query_params} { variable wcount_cache; variable bcount_cache; set data [dict create]; dict set data bot_name [html_escape [::arm::cfg:get botname]]; dict set data egg_version [lindex $::version 0]; dict set data armour_version "[::arm::cfg:get version] (rev: [::arm::cfg:get revision])"; dict set data uptime [::arm::userdb:timeago $::uptime]; dict set data users_count [dict size $::arm::dbusers]; dict set data channels_count [expr {[dict size $::arm::dbchans] - 1}]; dict set data white_count $wcount_cache; dict set data black_count $bcount_cache; return [render_template "dashboard_page" $data] }
    proc events_page {page query_params} {variable items_per_page; set offset [expr {($page - 1) * $items_per_page}]; ::arm::db:connect; set total_items [lindex [::arm::db:query "SELECT COUNT(*) FROM cmdlog"] 0]; set rows [::arm::db:query "SELECT timestamp, user, command, params, bywho FROM cmdlog ORDER BY timestamp DESC LIMIT $items_per_page OFFSET $offset"]; ::arm::db:close; set body "<h1>Recent Events</h1><input type='text' id='eventFilterInput' onkeyup=\"filterTable('eventFilterInput', 'eventsTable')\" placeholder='Filter events...'>"; append body "<table id='eventsTable'><thead><tr><th>Timestamp</th><th>User</th><th>Command</th><th>Parameters</th><th>Source</th></tr></thead><tbody>"; foreach row $rows {lassign $row ts user cmd params bywho; append body "<tr><td>[clock format $ts -format {%Y-%m-%d %H:%M:%S}]</td><td>[html_escape $user]</td><td>[html_escape $cmd]</td><td>[html_escape $params]</td><td>[html_escape $bywho]</td></tr>\n"}; append body "</tbody></table>"; append body [render_pagination "/events" $page $total_items]; return $body}
    proc users_page {page query_params csrf_token} { variable items_per_page; set offset [expr {($page - 1) * $items_per_page}]; set body ""; ::arm::db:connect; set total_items [lindex [::arm::db:query "SELECT COUNT(*) FROM users"] 0]; set users [::arm::db:query "SELECT id, user, xuser, email, languages FROM users ORDER BY user LIMIT $items_per_page OFFSET $offset"]; set user_ids [list]; foreach user_row $users { lappend user_ids [lindex $user_row 0] }; set levels_by_user [dict create]; set greets_by_user [dict create]; set chan_names [dict create]; if {[llength $user_ids] > 0} { set user_id_list [join $user_ids ","]; set all_levels [::arm::db:query "SELECT uid, cid, level FROM levels WHERE uid IN ($user_id_list) ORDER BY uid, cid"]; foreach level_row $all_levels { lassign $level_row l_uid l_cid l_level; dict lappend levels_by_user $l_uid [list $l_cid $l_level] }; set all_greets [::arm::db:query "SELECT uid, cid, greet FROM greets WHERE uid IN ($user_id_list)"]; foreach greet_row $all_greets { lassign $greet_row g_uid g_cid g_greet; dict set greets_by_user $g_uid $g_cid $g_greet } }; set all_channels [::arm::db:query "SELECT id, chan FROM channels"]; foreach chan_row $all_channels { lassign $chan_row c_id c_name; dict set chan_names $c_id $c_name }; ::arm::db:close; append body "<h1>User Management</h1><input type='text' id='userFilterInput' onkeyup=\"filterTable('userFilterInput', 'usersTable')\" placeholder='Filter users...'>"; append body "<table id='usersTable'><thead><tr><th>User Details</th></tr></thead><tbody>"; foreach user_row $users { lassign $user_row uid user xuser email languages; append body "<tr><td><details><summary><b>[html_escape $user]</b> (Account: [expr {$xuser eq "" ? "<i>none</i>" : [html_escape $xuser]}], UID: $uid)</summary>"; append body "<form action='/update-user' method='POST' style='margin-top: 1em; border-left: 2px solid #ccc; padding-left: 1em;'><input type='hidden' name='csrf_token' value='$csrf_token'><input type='hidden' name='uid' value='$uid'><h4>User Settings</h4><div class='grid'><div><label>Email</label><input type='email' name='email' value='[html_escape $email]'></div><div><label>Languages</label><input type='text' name='languages' placeholder='EN, FR' value='[html_escape $languages]'></div></div><h4>Channel-Specific Settings</h4>"; append body "<table><thead><tr><th>Channel</th><th>Access Level</th><th>On-Join Greeting</th></tr></thead><tbody>"; if {[dict exists $levels_by_user $uid]} { foreach level_pair [dict get $levels_by_user $uid] { lassign $level_pair cid level; set chan_name [dict get $chan_names $cid]; set greet ""; if {[dict exists $greets_by_user $uid $cid]} { set greet [dict get $greets_by_user $uid $cid] }; append body "<tr><td><b>[html_escape $chan_name]</b></td><td>[html_escape $level]</td><td><input type='text' name='greet_${cid}' value='[html_escape $greet]'></td></tr>" } }; append body "</tbody></table><button type='submit'>Save All User Changes</button></form>"; append body "<hr><h4>Destructive Actions</h4><div class='grid'>"; append body "<div><form action='/reset-password' method='POST' onsubmit=\"return confirm('Are you sure you want to reset this user\\'s password? A note with the new password will be sent to you.');\"><input type='hidden' name='csrf_token' value='$csrf_token'><input type='hidden' name='uid' value='$uid'><button class='secondary' type='submit'>Reset Password</button></form></div>"; append body "<div><form action='/delete-user' method='POST' onsubmit=\"return confirm('DANGER: Are you absolutely sure you want to permanently delete this user and all their access?');\"><input type='hidden' name='csrf_token' value='$csrf_token'><input type='hidden' name='uid' value='$uid'><button class='danger' type='submit'>Delete User</button></form></div></div></details></td></tr>" }; append body "</tbody></table>"; append body [render_pagination "/users" $page $total_items]; return $body }
    proc channels_page {query_params csrf_token} { set body "<h1>Channel Management</h1><table id='channelsTable'><thead><tr><th>Channel Details</th></tr></thead><tbody>"; set toggle_settings {strictop strictvoice autotopic operop trakka quote}; ::arm::db:connect; set channels [::arm::db:query "SELECT id, chan FROM channels WHERE chan != '*' ORDER BY chan"]; foreach chan_row $channels { lassign $chan_row cid chan; set settings [dict create]; set setting_rows [::arm::db:query "SELECT setting, value FROM settings WHERE cid=$cid"]; foreach setting_row $setting_rows {lassign $setting_row key val; dict set settings $key $val}; append body "<tr><td><details><summary><b>[html_escape $chan]</b></summary>"; append body "<form action='/update-channel' method='POST' style='margin-top: 1em; border-left: 2px solid #ccc; padding-left: 1em;'><input type='hidden' name='csrf_token' value='$csrf_token'><input type='hidden' name='cid' value='$cid'>"; set current_mode ""; if {[dict exists $settings mode]} { set current_mode [dict get $settings mode] }; set url_val ""; if {[dict exists $settings url]} { set url_val [html_escape [dict get $settings url]] }; set desc_val ""; if {[dict exists $settings desc]} { set desc_val [html_escape [dict get $settings desc]] }; append body "<div><label for='mode_$cid'>Mode</label><select id='mode_$cid' name='mode'>"; foreach mode_option {on off secure} {set selected [expr {$current_mode eq $mode_option ? "selected" : ""}]; append body "<option value='$mode_option' $selected>[string totitle $mode_option]</option>"}; append body "</select></div>"; append body "<label for='url_$cid'>URL</label><input type='text' id='url_$cid' name='url' value='$url_val'><label for='desc_$cid'>Description</label><input type='text' id='desc_$cid' name='desc' value='$desc_val'>"; set kl_kicks ""; set kl_mins ""; set kl_modes ""; set kl_duration ""; if {[dict exists $settings kicklock]} { set kicklock_val [dict get $settings kicklock]; if {[regexp {^(\d+):(\d+):(\+?[A-Za-z0-9]+):(\d+)$} $kicklock_val -> kl_kicks kl_mins kl_modes kl_duration]} {} }; append body "<fieldset><legend><h4>Kick-Lock</h4></legend><div class='grid'>"; append body "<div><label>Kicks to trigger</label><input type='number' name='kicklock_kicks' placeholder='e.g., 3' value='$kl_kicks'></div>"; append body "<div><label>Within (minutes)</label><input type='number' name='kicklock_mins' placeholder='e.g., 5' value='$kl_mins'></div>"; append body "<div><label>Modes to set</label><input type='text' name='kicklock_modes' placeholder='e.g., +r' value='$kl_modes'></div>"; append body "<div><label>Duration (minutes)</label><input type='number' name='kicklock_duration' placeholder='e.g., 30' value='$kl_duration'></div>"; append body "</div></fieldset>"; append body "<h4>Toggles</h4><div class='grid'>"; foreach setting $toggle_settings { set current_val "off"; if {[dict exists $settings $setting] && [dict get $settings $setting] eq "on"} { set current_val "on" }; append body "<div><label for='${setting}_$cid'>[string totitle $setting]</label><select id='${setting}_$cid' name='$setting'>"; append body "<option value='on' [expr {$current_val eq "on" ? "selected" : ""}]>On</option><option value='off' [expr {$current_val eq "off" ? "selected" : ""}]>Off</option></select></div>" }; append body "</div><button type='submit' style='margin-top:1em;'>Update [html_escape $chan]</button></form></details></td></tr>" }; ::arm::db:close; append body "</tbody></table>"; return $body }
    proc lists_page {page query_params csrf_token} { variable items_per_page; set offset [expr {($page - 1) * $items_per_page}]; set all_white_ids [list]; set all_black_ids [list]; foreach id [lsort -integer [dict keys $::arm::entries]] { set type [dict get $::arm::entries $id type]; if {$type eq "white"} { lappend all_white_ids $id } elseif {$type eq "black"} { lappend all_black_ids $id } }; set total_white [llength $all_white_ids]; set paged_white_ids [lrange $all_white_ids $offset [expr {$offset + $items_per_page - 1}]]; set white_rows ""; foreach id $paged_white_ids { dict with ::arm::entries $id { append white_rows "<tr><td><input type='checkbox' name='ids' value='$id'></td><td>$id</td><td>[html_escape $chan]</td><td>[html_escape $method]</td><td>[html_escape $value]</td><td>[::arm::list:action $id]</td><td>[html_escape $reason]</td><td><button class='tertiary' type='button' onclick=\"removeEntry(this, '$id')\">Remove</button></td></tr>\n" } }; if {$white_rows eq ""} { set white_rows {<tr><td colspan="8" style="text-align:center;">No whitelist entries found.</td></tr>} }; set total_black [llength $all_black_ids]; set paged_black_ids [lrange $all_black_ids $offset [expr {$offset + $items_per_page - 1}]]; set black_rows ""; foreach id $paged_black_ids { dict with ::arm::entries $id { append black_rows "<tr><td><input type='checkbox' name='ids' value='$id'></td><td>$id</td><td>[html_escape $chan]</td><td>[html_escape $method]</td><td>[html_escape $value]</td><td>[::arm::list:action $id]</td><td>[html_escape $reason]</td><td><button class='tertiary' type='button' onclick=\"removeEntry(this, '$id')\">Remove</button></td></tr>\n" } }; if {$black_rows eq ""} { set black_rows {<tr><td colspan="8" style="text-align:center;">No blacklist entries found.</td></tr>} }; set data [dict create]; dict set data CSRF_TOKEN $csrf_token; dict set data WHITELIST_ROWS $white_rows; dict set data BLACKLIST_ROWS $black_rows; dict set data WHITELIST_PAGINATION [render_pagination "/lists" $page $total_white]; dict set data BLACKLIST_PAGINATION [render_pagination "/lists" $page $total_black]; return [render_template "lists_page_body" $data] }
}
# --- SCRIPT INITIALIZATION ---
::arm::web::start_server
