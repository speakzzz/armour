# ------------------------------------------------------------------------------------------------
# WeatherGov Plugin for Armour (v1.5)
# ------------------------------------------------------------------------------------------------
#
# Provides weather information for locations within the United States via the weather.gov API.
#
# v1.1 - Added handling for the API's 301 redirect.
# v1.2 - Added a diagnostic version command.
# v1.3 - Corrected command registration and proc naming convention.
# v1.4 - Correctly handles HTTP 301 redirects by checking the HTTP status code and Location header.
# v1.5 - Correctly handles relative URLs provided in the HTTP Location header.
#
# ------------------------------------------------------------------------------------------------

package require json
package require http 2
package require tls 1.7

# -- Register the commands with Armour's command handler
set addcmd(climate)     { climate 1 pub msg dcc }
set addcmd(climate_ver) { climate 1 pub msg dcc }

# --- DIAGNOSTIC COMMAND ---
proc climate:cmd:climate_ver {0 1 2 3 {4 ""} {5 ""}} {
    lassign [proc:setvars $0 $1 $2 $3 $4 $5] type stype target starget nick uh hand source chan arg
    reply $type $target "WeatherGov Plugin v1.5 is correctly loaded."
}

# --- MAIN COMMAND ---
proc climate:cmd:climate {0 1 2 3 {4 ""} {5 ""}} {
    lassign [proc:setvars $0 $1 $2 $3 $4 $5] type stype target starget nick uh hand source chan arg

    set cmd "weathergov"
    lassign [db:get id,user users curnick $nick] uid user
    set chan [userdb:get:chan $user $chan]
    set cid [db:get id channels chan $chan]
    if {$cid eq ""} { set cid 1 }

    set ison [arm::db:get value settings setting "weathergov" cid $cid]
    if {$ison ne "on"} {
        debug 1 "\002cmd:weathergov:\002 weathergov not enabled on $chan. Use: \002modchan $chan weathergov on\002"
        return
    }

    set allowed [cfg:get weather:allow];
    set allow 0
    if {$uid eq ""} { set authed 0 } else { set authed 1 }
    if {$allowed eq 0} { return } \
    elseif {$allowed eq 1} { set allow 1 } \
    elseif {$allowed >= 2} { if {[isop $nick $chan] || [isvoice $nick $chan] || $authed} { set allow 1 } }
    if {[userdb:isIgnored $nick $cid]} { set allow 0 }
    if {!$allow} { return }

    set location [join $arg]
    if {$location eq ""} {
        set dbcity [join [db:get value settings setting city uid $uid]]
        if {$dbcity ne ""} {
            set location $dbcity
        } else {
            reply $type $target "\002usage:\002 climate <city, state | latitude,longitude>"
            return
        }
    }

    http::register https 443 [list ::tls::socket -autoservername true]
    set headers [list User-Agent "MyArmourBot/1.0 (mybot@example.com)"]

    set geo_query [http::formatQuery q $location format "json"]
    if {[catch {http::geturl "https://nominatim.openstreetmap.org/search?$geo_query" -headers $headers} tok]} {
        reply $type $target "\002error:\002 Could not connect to geocoding service."
        return
    }
    set geo_data [::json::json2dict [http::data $tok]]
    http::cleanup $tok

    if {[llength $geo_data] == 0} {
        reply $type $target "\002error:\002 Location not found: $location"
        return
    }

    set first_result [lindex $geo_data 0]
    set lat [dict get $first_result "lat"]
    set lon [dict get $first_result "lon"]
    set display_name [dict get $first_result "display_name"]

    if {[catch {http::geturl "https://api.weather.gov/points/$lat,$lon" -headers $headers} tok]} {
        reply $type $target "\002error:\002 Could not connect to weather.gov API."
        return
    }
    
    set ncode [http::ncode $tok]
    set points_data [http::data $tok]
    set meta [http::meta $tok]

    # --- START OF FIX (v1.5) ---
    if {$ncode == 301} {
        debug 1 "\002cmd:weathergov:\002 API returned HTTP 301. Following redirect."
        set new_points_url [dict get $meta "Location"]
        http::cleanup $tok

        if {$new_points_url eq ""} {
            reply $type $target "\002error:\002 API sent a redirect without a location."
            return
        }
        
        # Check if the URL is relative (starts with /) and prepend the base URL if it is.
        if {[string index $new_points_url 0] eq "/"} {
            set new_points_url "https://api.weather.gov$new_points_url"
        }
        
        if {[catch {http::geturl $new_points_url -headers $headers} tok]} {
            reply $type $target "\002error:\002 Could not follow API redirect to $new_points_url"
            return
        }
        set points_data [http::data $tok]

    } elseif {$ncode != 200} {
         set points_json [::json::json2dict $points_data]
         set detail [dict get $points_json "detail"]
         reply $type $target "\002error:\002 $detail (HTTP $ncode)"
         http::cleanup $tok
         return
    }
    # --- END OF FIX ---
    
    http::cleanup $tok
    set points_json [::json::json2dict $points_data]
    set forecast_url [dict get $points_json "properties" "forecast"]

    if {$forecast_url eq ""} {
        reply $type $target "\002error:\002 Could not determine the forecast URL from the API response."
        return
    }

    if {[catch {http::geturl $forecast_url -headers $headers} tok]} {
        reply $type $target "\002error:\002 Could not retrieve forecast data."
        return
    }
    set forecast_data [http::data $tok]
    http::cleanup $tok
    set forecast_json [::json::json2dict $forecast_data]

    set periods [dict get $forecast_json "properties" "periods"]
    set current_period [lindex $periods 0]

    set period_name [dict get $current_period "name"]
    set temp [dict get $current_period "temperature"]
    set temp_unit [dict get $current_period "temperatureUnit"]
    set wind_speed [dict get $current_period "windSpeed"]
    set wind_direction [dict get $current_period "windDirection"]
    set short_forecast [dict get $current_period "shortForecast"]
    set detailed_forecast [dict get $current_period "detailedForecast"]

    reply $type $target "\002Weather for $display_name:\002 \002$period_name:\002 $temp°$temp_unit, $short_forecast. Wind: $wind_speed from the $wind_direction. -- $detailed_forecast"

    log:cmdlog BOT $chan $cid $user $uid [string toupper $cmd] [join $arg] "$source" "" "" ""
}

putlog "\[A\] Armour: loaded plugin: weathergov"
