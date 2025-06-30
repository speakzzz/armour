# armour/packages/arm-24_web.tcl - An enhanced, self-contained web interface for Armour
# This version includes comprehensive permission checks for all user management actions.

namespace eval ::arm::web {

    variable sessions [dict create]
    variable items_per_page 25
    
    # --- START: Caching Optimization ---
    variable wcount_cache 0
    variable bcount_cache 0

    proc update_list_counts {} {
        variable wcount_cache
        variable bcount_cache
        
        # This is the expensive operation
        set wcount_cache [dict size [dict filter $::arm::entries script {id data} {expr {[dict get $data type] eq "white"}}]]
        set bcount_cache [dict size [dict filter $::arm::entries script {id data} {expr {[dict get $data type] eq "black"}}]]
        
        ::arm::debug 4 "\[@\] Armour Web: Updated list counts cache (W: $wcount_cache, B: $bcount_cache)."
    }

    # Run the update procedure every 5 minutes
    bind cron - "*/5 * * * *" ::arm::web::update_list_counts
    # And run it once now to initialize the cache
    update_list_counts
    # --- END: Caching Optimization ---

    # --- CORE SERVER PROCEDURES ---

    proc start_server {} {
        if {![::arm::cfg:get web:enable]} { return }
        set port [::arm::cfg:get web:port]
        set bind_ip [::arm::cfg:get web:bind]
        if {$bind_ip eq ""} { set bind_ip "0.0.0.0" }
        if {[catch {socket -server ::arm::web::accept -myaddr $bind_ip $port} sock]} {
            ::arm::debug 0 "\[@\] Armour: \x0304(error)\x03 Could not open server socket on $bind_ip port $port. Error: $sock"
            return
        }
        ::arm::debug 0 "\[@\] Armour: Starting web interface on $bind_ip port $port"
    }

    proc accept {sock addr p} {
        variable sessions
        fconfigure $sock -buffering line -translation lf
        if {[eof $sock] || [catch {gets $sock request_line}]} { catch {close $sock}; return }
        set headers [dict create]
        while {[gets $sock line] > 0 && $line ne "\r"} { if {[regexp {^([^:]+): (.*)} $line -> key value]} { dict set headers [string trim $key] [string trim $value] } }
        lassign $request_line method request_uri version
        set query_params [dict create]
        if {[string first "?" $request_uri] != -1} {
            lassign [split $request_uri "?"] path query_string
            foreach pair [split $query_string &] { lassign [split $pair =] key value; dict set query_params [url_decode $key] [url_decode $value] }
        } else { set path $request_uri }
        set page 1
        if {[dict exists $query_params page]} { set page_val [dict get $query_params page]; if {[string is integer -strict $page_val] && $page_val > 0} { set page $page_val } }
        set user ""
        if {[dict exists $headers Cookie]} {
            set cookie_str [dict get $headers Cookie]
            if {[regexp {session_id=([^; ]+)} $cookie_str -> session_id] && [dict exists $sessions $session_id]} {
                set user [dict get $sessions $session_id]
                if {[::arm::userdb:get:level $user *] < [::arm::cfg:get web:level]} { set user "" }
            }
        }
        set post_data ""
        if {$method eq "POST"} {
            set content_length 0
            if {[dict exists $headers "Content-Length"]} { set content_length [dict get $headers "Content-Length"] }
            if {$content_length > 0} { set post_data [read $sock $content_length] }
        }
        if {$user eq ""} {
            if {$path eq "/login"} { if {$method eq "POST"} { process_login $sock $post_data } else { send_page $sock "Login" [login_page] } } else { redirect $sock "/login" }
        } else {
            # Pass the authenticated admin 'user' to all user modification procedures
            switch -exact -- $path {
                "/" { send_page $sock "Dashboard" [dashboard_page] }
                "/lists" { send_page $sock "Manage Lists" [lists_page $page] }
                "/users" { send_page $sock "Manage Users" [users_page $page $query_params] }
                "/channels" { send_page $sock "Manage Channels" [channels_page] }
                "/events" { send_page $sock "Recent Events" [events_page $page] }
                "/login" { redirect $sock "/" }
                "/logout" { logout_handler $sock $headers }
                "/add-entry" { if {$method eq "POST"} { process_add_entry $sock $post_data $user } else { redirect $sock "/lists" } }
                "/remove-entry" { if {$method eq "POST"} { process_remove_entry $sock $post_data } else { redirect $sock "/lists" } }
                "/update-access" { if {$method eq "POST"} { process_update_access $sock $post_data $user } else { redirect $sock "/users" } }
                "/update-channel" { if {$method eq "POST"} { process_update_channel $sock $post_data } else { redirect $sock "/channels" } }
                "/update-user" { if {$method eq "POST"} { process_update_user $sock $post_data $user } else { redirect $sock "/users" } }
                "/reset-password" { if {$method eq "POST"} { process_reset_password $sock $post_data $user } else { redirect $sock "/users" } }
                "/delete-user" { if {$method eq "POST"} { process_delete_user $sock $post_data $user } else { redirect $sock "/users" } }
                default { send_page $sock "Not Found" "<h2>404 Not Found</h2>" "404 Not Found" }
            }
        }
        flush $sock
        catch {close $sock}
    }

    # --- UTILITY PROCEDURES ---
    
    proc url_decode {str} { regsub -all {\+} $str { } str; while {[regexp -indices -- {%([0-9a-fA-F]{2})} $str match]} { set hex [string range $str [expr {[lindex $match 0] + 1}] [lindex $match 1]]; scan $hex %x char_code; set str [string replace $str [lindex $match 0] [lindex $match 1] [format %c $char_code]] }; return $str }
    proc html_escape {str} { return [string map {& &amp; < &lt; > &gt; \" &quot;} $str] }
    proc redirect {sock location} { puts $sock "HTTP/1.0 302 Found\r\nLocation: $location\r\n\r\n" }
    proc render_pagination {path current_page total_items} { variable items_per_page; if {$total_items <= $items_per_page} { return "" }; set total_pages [expr {ceil(double($total_items) / $items_per_page)}]; set pagination_html "<div class='pagination' style='text-align:center; margin-top: 1em;'>"; if {$current_page > 1} { append pagination_html "<a href='$path?page=[expr {$current_page - 1}]'>&laquo; Previous</a>" }; append pagination_html " <span style='margin: 0 1em;'>Page $current_page of $total_pages</span> "; if {$current_page < $total_pages} { append pagination_html "<a href='$path?page=[expr {$current_page + 1}]'>Next &raquo;</a>" }; append pagination_html "</div>"; return $pagination_html }
    proc send_page {sock title body {status "200 OK"}} { set nav ""; if {$title ne "Login" && $title ne "Error"} { set nav {<nav><a href="/">Dashboard</a> | <a href="/lists">Lists</a> | <a href="/users">Users</a> | <a href="/channels">Channels</a> | <a href="/events">Events</a> | <a href="/logout">Logout</a></nav><hr>} }; set javascript {<script>function filterTable(i,t){let e,n,l,a,d,r,c,s;for(e=document.getElementById(i),n=e.value.toUpperCase(),l=document.getElementById(t),a=l.getElementsByTagName("tr"),r=1;r<a.length;r++){let i=!1;for(d=a[r].getElementsByTagName("td"),c=0;c<d.length;c++)if(d[c]&&(s=d[c].textContent||d[c].innerText,s.toUpperCase().indexOf(n)>-1)){i=!0;break}i?a[r].style.display="":a[r].style.display="none"}}</script>}; set html "<!DOCTYPE html><html><head><title>Armour - $title</title>$javascript<link rel='stylesheet' href='https://unpkg.com/simpledotcss/simple.min.css'></head><body><main>$nav$body</main></body></html>"; puts $sock "HTTP/1.0 $status\r\nContent-Type: text/html\r\nContent-Length: [string length $html]\r\n\r\n$html" }
    
    # --- NEW HELPER FOR SECURITY CHECKS ---
    proc can_admin_modify_target {admin_uid target_uid} {
        ::arm::db:connect
        # Get admin's max level
        set admin_levels [::arm::db:query "SELECT level FROM levels WHERE uid=$admin_uid"]
        set admin_max_level 0
        foreach level_row $admin_levels {
            if {[lindex $level_row 0] > $admin_max_level} { set admin_max_level [lindex $level_row 0] }
        }

        # Get target's max level
        set target_levels [::arm::db:query "SELECT level FROM levels WHERE uid=$target_uid"]
        set target_max_level 0
        foreach level_row $target_levels {
            if {[lindex $level_row 0] > $target_max_level} { set target_max_level [lindex $level_row 0] }
        }
        ::arm::db:close
        
        # Owners can do anything. Otherwise, admin's level must be strictly greater than target's.
        if {$admin_max_level == 500} { return 1 }
        if {$admin_max_level > $target_max_level} { return 1 }

        return 0
    }

    # --- ACTION HANDLERS ---
    proc process_login {sock post_data} {variable sessions; if {[catch {set form_data [dict create]; foreach pair [split $post_data &] {lassign [split $pair =] key value; dict set form_data [url_decode $key] [url_decode $value]}; set username ""; set password ""; if {[dict exists $form_data username]} {set username [dict get $form_data username]}; if {[dict exists $form_data password]} {set password [dict get $form_data password]}; set authenticated 0; if {$username ne "" && $password ne ""} {foreach {uid udata} $::arm::dbusers {if {[string equal -nocase [dict get $udata user] $username]} {if {[dict get $udata pass] eq [::arm::userdb:encrypt $password]} {set authenticated 1}; break}}}; if {$authenticated && [::arm::userdb:get:level $username *] >= [::arm::cfg:get web:level]} {set session_id [::sha1::sha1 -hex "[clock clicks][clock seconds][expr {rand()}]"]; dict set sessions $session_id $username; puts $sock "HTTP/1.0 302 Found\r\nSet-Cookie: session_id=$session_id; Path=/; HttpOnly; SameSite=Strict\r\nLocation: /\r\n\r\n"} else {send_page $sock "Login" [login_page "Invalid credentials or insufficient access level."]}} error_message]} {::arm::debug 0 "\n\n\x0304FATAL LOGIN ERROR:\x03 $error_message\n$::errorInfo\n"; send_page $sock "Error" "<h2>500 Internal Server Error</h2><p>An error occurred.</p>" "500 Internal Server Error"}}
    proc logout_handler {sock headers} {variable sessions; if {[dict exists $headers Cookie]} {if {[regexp {session_id=([^; ]+)} [dict get $headers Cookie] -> session_id]} {dict unset sessions $session_id}}; puts $sock "HTTP/1.0 302 Found\r\nSet-Cookie: session_id=deleted; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT\r\nLocation: /login\r\n\r\n"}
    proc process_add_entry {sock post_data user} {set form_data [dict create]; foreach pair [split $post_data &] {lassign [split $pair =] key value; dict set form_data $key [url_decode $value]}; ::arm::db:add [string toupper [string index [dict get $form_data list] 0]] [dict get $form_data chan] [dict get $form_data method] [dict get $form_data value] "$user (web)" [dict get $form_data action] "1:1:1" [dict get $form_data reason]; redirect $sock "/lists"}
    proc process_remove_entry {sock post_data} {lassign [split $post_data =] key id; ::arm::db:rem [url_decode $id]; redirect $sock "/lists"}
    
    proc process_update_access {sock post_data admin_user} {
        set form_data [dict create]; foreach pair [split $post_data &] {lassign [split $pair =] key value; dict set form_data [url_decode $key] [url_decode $value]}
        set target_uid [dict get $form_data uid]; set cid [dict get $form_data cid]; set new_level [dict get $form_data level]
        set admin_uid [::arm::db:get id users user $admin_user]
        if {![can_admin_modify_target $admin_uid $target_uid]} { redirect $sock "/users?error=access_denied"; return }
        ::arm::db:connect; ::arm::db:query "UPDATE levels SET level='$new_level' WHERE uid='$target_uid' AND cid='$cid'"; ::arm::db:close; redirect $sock "/users"
    }
    
    proc process_update_channel {sock post_data} {set form_data [dict create]; foreach pair [split $post_data &] {lassign [split $pair =] key value; dict set form_data [url_decode $key] [url_decode $value]}; set cid [dict get $form_data cid]; ::arm::db:connect; foreach setting [dict keys $form_data] {set value [dict get $form_data $setting]; if {$setting eq "cid"} continue; set existing_value [lindex [::arm::db:query "SELECT value FROM settings WHERE cid='$cid' AND setting='[::arm::db:escape $setting]'"] 0]; if {$existing_value eq ""} {::arm::db:query "INSERT INTO settings (cid, setting, value) VALUES ('$cid', '[::arm::db:escape $setting]', '[::arm::db:escape $value]')" } else {::arm::db:query "UPDATE settings SET value='[::arm::db:escape $value]' WHERE cid='$cid' AND setting='[::arm::db:escape $setting]'"}; dict set $::arm::dbchans $cid $setting $value}; ::arm::db:close; redirect $sock "/channels"}

    proc process_update_user {sock post_data admin_user} {
        set form_data [dict create]; foreach pair [split $post_data &] {lassign [split $pair =] key value; dict set form_data [url_decode $key] [url_decode $value]}
        set target_uid [dict get $form_data uid]
        set admin_uid [::arm::db:get id users user $admin_user]
        if {![can_admin_modify_target $admin_uid $target_uid]} { redirect $sock "/users?error=access_denied"; return }
        ::arm::db:connect
        ::arm::db:query "UPDATE users SET email='[::arm::db:escape [dict get $form_data email]]', languages='[::arm::db:escape [dict get $form_data languages]]' WHERE id=$target_uid"
        foreach key [dict keys $form_data] { if {[string match "greet_*" $key]} { set cid [lindex [split $key "_"] 1]; set greet_val [::arm::db:escape [dict get $form_data $key]]; set exists [lindex [::arm::db:query "SELECT greet FROM greets WHERE uid=$target_uid AND cid=$cid"] 0]; if {$exists eq ""} { if {$greet_val ne ""} { ::arm::db:query "INSERT INTO greets (cid, uid, greet) VALUES ($cid, $target_uid, '$greet_val')" } } else { if {$greet_val eq ""} { ::arm::db:query "DELETE FROM greets WHERE uid=$target_uid AND cid=$cid" } else { ::arm::db:query "UPDATE greets SET greet='$greet_val' WHERE uid=$target_uid AND cid=$cid" } } } }
        ::arm::db:close
        redirect $sock "/users"
    }

    proc process_reset_password {sock post_data admin_user} {
        set target_uid [lindex [split [lindex [split $post_data &] 0] =] 1]
        set admin_uid [::arm::db:get id users user $admin_user]
        if {![can_admin_modify_target $admin_uid $target_uid]} { redirect $sock "/users?error=access_denied"; return }
        set new_pass [::arm::randpass]; set enc_pass [::arm::userdb:encrypt $new_pass]; set target_user [::arm::db:get user users id $target_uid]
        ::arm::userdb:user:set pass $enc_pass id $target_uid
        set note "Password for user '$target_user' (UID: $target_uid) has been reset. New password is: $new_pass"
        ::arm::db:connect; ::arm::db:query "INSERT INTO notes (timestamp, from_u, from_id, to_u, to_id, read, note) VALUES ('[clock seconds]', 'Armour', '0', '$admin_user', '$admin_uid', 'N', '[::arm::db:escape $note]')"; ::arm::db:close
        redirect $sock "/users?msg=pass_reset_ok"
    }

    proc process_delete_user {sock post_data admin_user} {
        set target_uid [lindex [split [lindex [split $post_data &] 0] =] 1]
        set admin_uid [::arm::db:get id users user $admin_user]
        if {![can_admin_modify_target $admin_uid $target_uid]} { redirect $sock "/users?error=access_denied"; return }
        set target_user [::arm::db:get user users id $target_uid]
        ::arm::userdb:deluser $target_user $target_uid
        redirect $sock "/users"
    }

    # --- PAGE GENERATORS ---

    proc login_page {{error ""}} {if {$error ne ""} { set error "<p style='color:red;'>$error</p>" }; return "<h1>Armour Login</h1>$error<form method='POST' action='/login'><label>Username</label><input type='text' name='username' required><label>Password</label><input type='password' name='password' required><button type='submit'>Login</button></form>"}
    
    proc dashboard_page {} {
        variable wcount_cache
        variable bcount_cache
        return "<h1>Dashboard</h1><div class='grid'><article><h4>Bot Status</h4><ul><li><b>Bot Name:</b> [html_escape [::arm::cfg:get botname]]</li><li><b>Eggdrop Version:</b> [lindex $::version 0]</li><li><b>Armour Version:</b> [::arm::cfg:get version] (rev: [::arm::cfg:get revision])</li><li><b>Uptime:</b> [::arm::userdb:timeago $::uptime]</li></ul></article><article><h4>Database Stats</h4><ul><li><b>Registered Users:</b> [dict size $::arm::dbusers]</li><li><b>Managed Channels:</b> [expr {[dict size $::arm::dbchans] - 1}]</li><li><b>Whitelist Entries:</b> $wcount_cache</li><li><b>Blacklist Entries:</b> $bcount_cache</li></ul></article></div>"
    }

    proc events_page {page} {variable items_per_page; set offset [expr {($page - 1) * $items_per_page}]; ::arm::db:connect; set total_items [lindex [::arm::db:query "SELECT COUNT(*) FROM cmdlog"] 0]; set rows [::arm::db:query "SELECT timestamp, user, command, params, bywho FROM cmdlog ORDER BY timestamp DESC LIMIT $items_per_page OFFSET $offset"]; ::arm::db:close; set body "<h1>Recent Events</h1><input type='text' id='eventFilterInput' onkeyup=\"filterTable('eventFilterInput', 'eventsTable')\" placeholder='Filter events...'>"; append body "<table id='eventsTable'><thead><tr><th>Timestamp</th><th>User</th><th>Command</th><th>Parameters</th><th>Source</th></tr></thead><tbody>"; foreach row $rows {lassign $row ts user cmd params bywho; append body "<tr><td>[clock format $ts -format {%Y-%m-%d %H:%M:%S}]</td><td>[html_escape $user]</td><td>[html_escape $cmd]</td><td>[html_escape $params]</td><td>[html_escape $bywho]</td></tr>\n"}; append body "</tbody></table>"; append body [render_pagination "/events" $page $total_items]; return $body}
    
    proc users_page {page query_params} {
        variable items_per_page; set offset [expr {($page - 1) * $items_per_page}]; set body ""
        if {[dict exists $query_params error]} {
            if {[dict get $query_params error] eq "access_denied"} { append body "<p style='color:red; font-weight:bold;'>Error: Access Denied. You cannot modify a user with an access level equal to or greater than your own.</p>" }
        }
        if {[dict exists $query_params msg]} {
             if {[dict get $query_params msg] eq "pass_reset_ok"} { append body "<p style='color:green; font-weight:bold;'>Success: Password has been reset. A note containing the new password has been sent to you.</p>" }
        }
        ::arm::db:connect
        set total_items [lindex [::arm::db:query "SELECT COUNT(*) FROM users"] 0]
        set users [::arm::db:query "SELECT id, user, xuser, email, languages FROM users ORDER BY user LIMIT $items_per_page OFFSET $offset"]
        append body "<h1>User Management</h1><input type='text' id='userFilterInput' onkeyup=\"filterTable('userFilterInput', 'usersTable')\" placeholder='Filter users...'>"
        append body "<table id='usersTable'><thead><tr><th>User Details</th></tr></thead><tbody>"
        foreach user_row $users {
            lassign $user_row uid user xuser email languages
            append body "<tr><td><details><summary><b>$user</b> (Account: [expr {$xuser eq "" ? "<i>none</i>" : [html_escape $xuser]}], UID: $uid)</summary>"
            append body "<form action='/update-user' method='POST' style='margin-top: 1em; border-left: 2px solid #ccc; padding-left: 1em;'><input type='hidden' name='uid' value='$uid'><h4>User Settings</h4><div class='grid'><div><label>Email</label><input type='email' name='email' value='[html_escape $email]'></div><div><label>Languages</label><input type='text' name='languages' placeholder='EN, FR' value='[html_escape $languages]'></div></div><h4>Channel-Specific Settings</h4>"
            set levels [::arm::db:query "SELECT cid, level FROM levels WHERE uid=$uid ORDER BY cid"]
            append body "<table><thead><tr><th>Channel</th><th>Access Level</th><th>On-Join Greeting</th></tr></thead><tbody>"
            foreach level_row $levels { lassign $level_row cid level; set chan_name [::arm::db:get chan channels id $cid]; set greet [lindex [::arm::db:query "SELECT greet FROM greets WHERE uid=$uid AND cid=$cid"] 0]; append body "<tr><td><b>[html_escape $chan_name]</b></td><td><form style='display:inline-block; margin:0;' action='/update-access' method='POST'><input type='hidden' name='uid' value='$uid'><input type='hidden' name='cid' value='$cid'><input type='number' name='level' value='$level' style='width: 70px;'><button class='tertiary' type='submit'>Save</button></form></td><td><input type='text' name='greet_${cid}' value='[html_escape $greet]'></td></tr>"}
            append body "</tbody></table><button type='submit'>Save All User Changes</button></form>"
            append body "<hr><h4>Destructive Actions</h4><div class='grid'>"
            append body "<div><form action='/reset-password' method='POST' onsubmit=\"return confirm('Are you sure you want to reset this user\\'s password? A note with the new password will be sent to you.');\"><input type='hidden' name='uid' value='$uid'><button class='secondary' type='submit'>Reset Password</button></form></div>"
            append body "<div><form action='/delete-user' method='POST' onsubmit=\"return confirm('DANGER: Are you absolutely sure you want to permanently delete this user and all their access?');\"><input type='hidden' name='uid' value='$uid'><button class='secondary' style='background-color:#c82333; border-color:#c82333;' type='submit'>Delete User</button></form></div></div></details></td></tr>"
        }
        ::arm::db:close
        append body "</tbody></table>"
        append body [render_pagination "/users" $page $total_items]
        return $body
    }

    proc channels_page {} {
        set body "<h1>Channel Management</h1><table id='channelsTable'><thead><tr><th>Channel Details</th></tr></thead><tbody>"
        set toggle_settings {strictop strictvoice autotopic operop trakka quote}
        ::arm::db:connect; set channels [::arm::db:query "SELECT id, chan FROM channels WHERE chan != '*' ORDER BY chan"]
        foreach chan_row $channels {
            lassign $chan_row cid chan; set settings [dict create]
            set setting_rows [::arm::db:query "SELECT setting, value FROM settings WHERE cid=$cid"]
            foreach setting_row $setting_rows {lassign $setting_row key val; dict set settings $key $val}
            append body "<tr><td><details><summary><b>[html_escape $chan]</b></summary>"
            append body "<form action='/update-channel' method='POST' style='margin-top: 1em; border-left: 2px solid #ccc; padding-left: 1em;'><input type='hidden' name='cid' value='$cid'>"
            set current_mode ""; if {[dict exists $settings mode]} { set current_mode [dict get $settings mode] }
            set url_val ""; if {[dict exists $settings url]} { set url_val [html_escape [dict get $settings url]] }
            set desc_val ""; if {[dict exists $settings desc]} { set desc_val [html_escape [dict get $settings desc]] }
            set kicklock_val ""; if {[dict exists $settings kicklock]} { set kicklock_val [dict get $settings kicklock] }
            append body "<div class='grid'><div><label for='mode_$cid'>Mode</label><select id='mode_$cid' name='mode'>"
            foreach mode_option {on off secure} {set selected [expr {$current_mode eq $mode_option ? "selected" : ""}]; append body "<option value='$mode_option' $selected>[string totitle $mode_option]</option>"}
            append body "</select></div><div><label for='kicklock_$cid'>Kick-Lock <small>(kicks:mins:+modes:duration)</small></label><input type='text' id='kicklock_$cid' name='kicklock' placeholder='e.g., 3:5:+r:30' value='$kicklock_val'></div></div>"
            append body "<label for='url_$cid'>URL</label><input type='text' id='url_$cid' name='url' value='$url_val'><label for='desc_$cid'>Description</label><input type='text' id='desc_$cid' name='desc' value='$desc_val'>"
            append body "<h4>Toggles</h4><div class='grid'>"
            foreach setting $toggle_settings {
                set current_val "off"
                if {[dict exists $settings $setting] && [dict get $settings $setting] eq "on"} { set current_val "on" }
                append body "<div><label for='${setting}_$cid'>[string totitle $setting]</label><select id='${setting}_$cid' name='$setting'>"
                append body "<option value='on' [expr {$current_val eq "on" ? "selected" : ""}]>On</option><option value='off' [expr {$current_val eq "off" ? "selected" : ""}]>Off</option></select></div>"
            }
            append body "</div><button type='submit' style='margin-top:1em;'>Update [html_escape $chan]</button></form></details></td></tr>"
        }
        ::arm::db:close
        append body "</tbody></table>"
        return $body
    }

    proc lists_page {page} {
        variable items_per_page; set offset [expr {($page - 1) * $items_per_page}]; set all_white_ids [list]; set all_black_ids [list]
        foreach id [lsort -integer [dict keys $::arm::entries]] { set type [dict get $::arm::entries $id type]; if {$type eq "white"} { lappend all_white_ids $id } elseif {$type eq "black"} { lappend all_black_ids $id } }
        set add_form {<fieldset><legend><h2>Add New Entry</h2></legend><form action="/add-entry" method="POST"><div class="grid"><label for="list">List Type<select id="list" name="list" required><option value="white">Whitelist</option><option value="black">Blacklist</option></select></label><label for="chan">Channel<input type="text" id="chan" name="chan" value="*" required></label></div><div class="grid"><label for="method">Method<select id="method" name="method" required><option value="user">user</option><option value="host">host</option><option value="regex">regex</option><option value="text">text</option><option value="country">country</option><option value="asn">asn</option><option value="chan">chan</option></select></label><label for="action">Action<select id="action" name="action" required><option value="A">Accept</option><option value="V">Voice</option><option value="O">Op</option><option value="B">Kickban</option></select></label></div><label for="value">Value</label><input type="text" id="value" name="value" required><label for="reason">Reason</label><input type="text" id="reason" name="reason" required><button type="submit">Add Entry</button></form></fieldset>}
        set body "<h1>Manage Lists</h1><input type='text' id='listFilterInput' onkeyup=\"filterTable('listFilterInput', 'whitelistTable'); filterTable('listFilterInput', 'blacklistTable');\" placeholder='Filter lists by any value...'>$add_form"
        set total_white [llength $all_white_ids]; set paged_white_ids [lrange $all_white_ids $offset [expr {$offset + $items_per_page - 1}]]; append body "<h2>Whitelist</h2><table id='whitelistTable'><thead><tr><th>ID</th><th>Chan</th><th>Method</th><th>Value</th><th>Action</th><th>Reason</th><th></th></tr></thead><tbody>"
        foreach id $paged_white_ids {dict with ::arm::entries $id { append body "<tr><td>$id</td><td>[html_escape $chan]</td><td>[html_escape $method]</td><td>[html_escape $value]</td><td>[::arm::list:action $id]</td><td>[html_escape $reason]</td><td><form action='/remove-entry' method='POST'><input type='hidden' name='id' value='$id'><button class='tertiary' type='submit'>Remove</button></form></td></tr>\n" }}; append body "</tbody></table>"; append body [render_pagination "/lists" $page $total_white]
        set total_black [llength $all_black_ids]; set paged_black_ids [lrange $all_black_ids $offset [expr {$offset + $items_per_page - 1}]]; append body "<h2>Blacklist</h2><table id='blacklistTable'><thead><tr><th>ID</th><th>Chan</th><th>Method</th><th>Value</th><th>Action</th><th>Reason</th><th></th></tr></thead><tbody>"
        foreach id $paged_black_ids {dict with ::arm::entries $id { append body "<tr><td>$id</td><td>[html_escape $chan]</td><td>[html_escape $method]</td><td>[html_escape $value]</td><td>[::arm::list:action $id]</td><td>[html_escape $reason]</td><td><form action='/remove-entry' method='POST'><input type='hidden' name='id' value='$id'><button class='tertiary' type='submit'>Remove</button></form></td></tr>\n" }}; append body "</tbody></table>"; append body [render_pagination "/lists" $page $total_black]
        return $body
    }
}

# This line calls the procedure to start the server.
::arm::web::start_server
