# armour/packages/arm-24_web.tcl - A self-contained web interface for Armour

namespace eval ::arm::web {

    # Main procedure to start the web server socket
    proc start_server {} {
        if {![::arm::cfg:get web:enable]} { return }

        set port [::arm::cfg:get web:port]
        ::arm::debug 0 "\[@\] Armour: Starting self-contained web interface on port $port"
        
        # Open a server socket and set a fileevent to handle new connections
        if {[catch {socket -server ::arm::web::accept $port} sock]} {
            ::arm::debug 0 "\[@\] Armour: \x0304(error)\x03 Could not open server socket on port $port. Is another service using it?"
            return
        }
    }

    # This procedure is called when a new browser connects
    proc accept {sock addr p} {
        fconfigure $sock -buffering line
        fileevent $sock readable [list ::arm::web::handle_request $sock]
    }

    # This procedure handles the actual HTTP request
    proc handle_request {sock} {
        # Check for end-of-file, close if the browser disconnected
        if {[eof $sock] || [catch {gets $sock request_line}]} {
            catch {close $sock}
            return
        }
        
        # Read and ignore the rest of the browser headers
        while {[gets $sock line] > 0} {
            if {$line eq ""} break
        }
        
        # Simple router: We only respond to the root "/" page for now
        if {[lindex $request_line 1] eq "/"} {
            set html [dashboard_page]
            puts $sock "HTTP/1.0 200 OK"
            puts $sock "Content-Type: text/html"
            puts $sock "Content-Length: [string length $html]"
            puts $sock ""
            puts $sock $html
        } else {
            set response "404 Not Found"
            puts $sock "HTTP/1.0 404 Not Found"
            puts $sock "Content-Type: text/plain"
            puts $sock "Content-Length: [string length $response]"
            puts $sock ""
            puts $sock $response
        }
        
        close $sock
    }

    # This procedure generates the HTML for the dashboard page
    proc dashboard_page {} {
        set botnick $::botnick
        set uptime [::arm::userdb:timeago $::uptime]
        set mem [expr {[lindex [status mem] 1] / 1024}]
        
        set html "
        <!DOCTYPE html>
        <html lang='en'>
        <head>
            <meta charset='UTF-8'>
            <title>Armour Status: $botnick</title>
        </head>
        <body>
            <h1>Armour Status for $botnick</h1>
            <ul>
                <li><strong>Uptime:</strong> $uptime</li>
                <li><strong>Memory Usage:</strong> ${mem}K</li>
            </ul>
        </body>
        </html>"
        
        return $html
    }

}

# This line calls the procedure to start the server after the file has been loaded.
::arm::web::start_server
