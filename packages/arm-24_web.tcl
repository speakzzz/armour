# armour/packages/arm-24_web.tcl - A self-contained web interface for Armour

namespace eval ::arm::web {

    # --- HELPER PROCEDURES ---

    # Helper procedure to build a full HTML page with a consistent style
    proc build_page {title body} {
        set botnick $::botnick
        return "<!DOCTYPE html><html lang='en'><head><meta charset='UTF-8'><title>$title: $botnick</title><link rel='stylesheet' href='https://unpkg.com/simpledotcss/simple.min.css'></head><body><main>$body</main></body></html>"
    }

    # Helper procedure to generate the navigation bar
    proc navigation {} {
        return "<nav><a href='/'>Dashboard</a> | <a href='/lists'>Manage Lists</a></nav>"
    }

    # Helper procedure to parse URL-encoded form data (e.g., from a POST)
    proc parse_post_data {data} {
        set result [dict create]
        foreach pair [split $data &] {
            lassign [split $pair =] key value
            # Decode URL-encoded characters
            set value [string map {+ " " %23 # %2F / %3A : %3D = %26 &} $value]
            dict set result $key $value
        }
        return $result
    }

    # Helper procedure to send a redirect response to the browser
    proc redirect {sock url} {
        puts $sock "HTTP/1.0 302 Found"
        puts $sock "Location: $url"
        puts $sock "Content-Length: 0\r\n"
        close $sock
    }


    # --- CORE SERVER PROCEDURES ---

    # Main procedure to start the web server socket
    proc start_server {} {
        if {![::arm::cfg:get web:enable]} { return }
        set port [::arm::cfg:get web:port]
        if {[catch {socket -server ::arm::web::accept $port} sock]} {
            ::arm::debug 0 "\[@\] Armour: \x0304(error)\x03 Could not open server socket on port $port. Is another service using it? Error: $sock"
            return
        }
        ::arm::debug 0 "\[@\] Armour: Starting self-contained web interface on port $port"
    }

    # This procedure is called when a new browser connects
    proc accept {sock addr p} {
        fconfigure $sock -buffering line -translation lf
        fileevent $sock readable [list ::arm::web::handle_request $sock]
    }

    # This procedure handles the actual HTTP request and routes it
    proc handle_request {sock} {
        if {[eof $sock] || [catch {gets $sock request_line}]} {
            catch {close $sock}; return
        }
        
        lassign $request_line method path version
        set content_length 0
        
        # Read headers and find Content-Length for POST requests
        while {[gets $sock line] > 0 && $line ne "\r"} {
            if {[string match -nocase "Content-Length:*" $line]} {
                set content_length [string trim [lindex $line 1]]
            }
        }
        
        # Handle the request based on method and path
        if {$method eq "POST"} {
            set post_data [read $sock $content_length]
            set form_data [parse_post_data $post_data]
            switch -exact -- $path {
                "/add-entry"    { add_entry_handler $sock $form_data }
                "/delete-entry" { delete_entry_handler $sock $form_data }
                default         { Httpd_ReturnData $sock "text/html" [build_page "Not Found" "<h2>404 Not Found</h2>"] "404 Not Found" }
            }
        } elseif {$method eq "GET"} {
            switch -exact -- $path {
                "/"         { dashboard_page $sock }
                "/lists"    { lists_page $sock }
                default     { Httpd_ReturnData $sock "text/html" [build_page "Not Found" "<h2>404 Not Found</h2>"] "404 Not Found" }
            }
        } else {
            close $sock
        }
    }


    # --- PAGE HANDLERS (GET REQUESTS) ---

    proc dashboard_page {sock} {
        set uptime [::arm::userdb:timeago $::uptime]
        set mem [expr {[lindex [status mem] 1] / 1024}]
        set body "<h1>Armour Status</h1>[navigation]<p>This page provides a real-time overview of the bot's status.</p><ul><li><strong>Uptime:</strong> $uptime</li><li><strong>Memory Usage:</strong> ${mem}K</li></ul>"
        Httpd_ReturnData $sock "text/html" [build_page "Dashboard" $body]
    }

    proc lists_page {sock} {
        set body "<h1>Manage Lists</h1>[navigation]<h2>Whitelist</h2><table><thead><tr><th>ID</th><th>Chan</th><th>Method</th><th>Value</th><th>Action</th><th>Reason</th><th></th></tr></thead><tbody>"
        foreach id [lsort -integer [dict keys $::arm::entries]] {
            dict with ::arm::entries $id {
                if {$type eq "white"} {
                    append body "<tr><td>$id</td><td>$chan</td><td>$method</td><td>$value</td><td>[::arm::list:action $id]</td><td>$reason</td><td><form method='POST' action='/delete-entry' style='margin:0;'><input type='hidden' name='id' value='$id'><button type='submit'>Delete</button></form></td></tr>\n"
                }
            }
        }
        append body "</tbody></table><h2>Blacklist</h2><table><thead><tr><th>ID</th><th>Chan</th><th>Method</th><th>Value</th><th>Action</th><th>Reason</th><th></th></tr></thead><tbody>"
        foreach id [lsort -integer [dict keys $::arm::entries]] {
            dict with ::arm::entries $id {
                if {$type eq "black"} {
                    append body "<tr><td>$id</td><td>$chan</td><td>$method</td><td>$value</td><td>[::arm::list:action $id]</td><td>$reason</td><td><form method='POST' action='/delete-entry' style='margin:0;'><input type='hidden' name='id' value='$id'><button type='submit'>Delete</button></form></td></tr>\n"
                }
            }
        }
        append body "</tbody></table><hr><h2>Add New Entry</h2><form method='POST' action='/add-entry'><div class='grid'><label>List Type <select name='list' required><option value='B'>Blacklist</option><option value='W'>Whitelist</option></select></label><label>Channel <input type='text' name='chan' value='*' required></label></div><div class='grid'><label>Method <select name='method' required><option value='host'>host</option><option value='user'>user</option><option value='chan'>chan</option><option value='text'>text</option></select></label><label>Action <select name='action' required><option value='B'>Ban/Kick</option><option value='A'>Accept</option><option value='V'>Voice</option><option value='O'>Op</option></select></label></div><label>Value</label><input type='text' name='value' required><label>Reason / Reply</label><input type='text' name='reason' required><button type='submit'>Add Entry</button></form>"
        Httpd_ReturnData $sock "text/html" [build_page "Manage Lists" $body]
    }
    
    # Helper to send HTML response
    proc Httpd_ReturnData {sock type data {status "200 OK"}} {
        puts $sock "HTTP/1.0 $status"
        puts $sock "Content-Type: $type"
        puts $sock "Content-Length: [string length $data]\r\n"
        puts $sock $data
    }


    # --- FORM HANDLERS (POST REQUESTS) ---

    proc delete_entry_handler {sock form_data} {
        set id [dict get $form_data id]
        if {$id ne ""} { ::arm::db:rem $id }
        redirect $sock /lists
    }

    proc add_entry_handler {sock form_data} {
        set list   [dict get $form_data list]
        set chan   [dict get $form_data chan]
        set method [dict get $form_data method]
        set value  [dict get $form_data value]
        set action [dict get $form_data action]
        set reason [dict get $form_data reason]
        ::arm::db:add $list $chan $method $value "WebApp" $action "1:1:1" $reason
        redirect $sock /lists
    }
}

# This line calls the procedure to start the server after this file has been loaded.
::arm::web::start_server
