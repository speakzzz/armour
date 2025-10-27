# ------------------------------------------------------------------------------------------------
# WeatherGov Plugin for Armour (v1.7 - Final)
# ------------------------------------------------------------------------------------------------
#
# Provides weather information for locations within the United States via the weather.gov API.
# This version has been modified to use the OpenCage API for geocoding and reads its
# API key from armour.conf.
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
    reply $type $target "Climate (WeatherGov) Plugin v1.7 is correctly loaded."
}

# --- MAIN COMMAND ---
proc climate:cmd:climate {0 1 2 3 {4 ""} {5 ""}} {
    lassign [proc:setvars $0 $1 $2 $3 $4 $5] type stype target starget nick uh hand source chan arg

    set cmd "climate"
    lassign [db:get id,user users curnick $nick] uid user
    set chan [userdb:get:chan $user $chan]
    set cid [db:get id channels chan $chan]
    if {$cid eq ""} { set cid 1 }

    set ison [arm::db:get value settings setting "weathergov" cid $cid]
    if {$ison ne "on"} {
        debug 1 "\002cmd:climate:\002 weathergov not enabled on $chan. Use: \002modchan $chan weathergov on\002"
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

    # --- Geocoding via OpenCage API ---
    set apikey [cfg:get weather:key]
    if {$apikey eq ""} {
        reply $type $target "\002error:\002 OpenCage API key is not set in armour.conf. Please add: set cfg(weather:key) \"YOUR_KEY\""
        return
    }
    http::register https 443 [list ::tls::socket -autoservername true]
    set headers [list User-Agent "ArmourWeatherPlugin/1.7 ($::botnick on $::network)"]
    set geo_query [http::formatQuery q $location key $apikey]

    if {[catch {http::geturl "https://api.opencagedata.com/geocode/v1/json?$geo_query" -headers $headers} tok]} {
        reply $type $target "\002error:\002 Could not connect to OpenCage geocoding service."
        return
    }

    set http_status [http::ncode $tok]
    set http_data [http::data $tok]
    http::cleanup $tok

    if {$http_status != 200} {
        reply $type $target "\002error:\002 OpenCage API returned a non-successful status: $http_status."
        return
    }

    set geo_data [::json::json2dict $http_data]
    set results [dict get $geo_data "results"]

    if {[llength $results] == 0} {
        reply $type $target "\002error:\002 Location not found: $location"
        return
    }

    set first_result [lindex $results 0]
    set geometry [dict get $first_result "geometry"]
    set lat [dict get $geometry "lat"]
    set lon [dict get $geometry "lng"]
    set display_name [dict get $first_result "formatted"]

    if {[catch {http::geturl "https://api.weather.gov/points/$lat,$lon" -headers $headers} tok]} {
        reply $type $target "\002error:\002 Could not connect to weather.gov API."
        return
    }
    
    set ncode [http::ncode $tok]
    set points_data [http::data $tok]
    set meta [http::meta $tok]
    
    if {$ncode == 301} {
        debug 1 "\002cmd:climate:\002 API returned HTTP 301. Following redirect."
        set new_points_url [dict get $meta "Location"]
        http::cleanup $tok

        if {$new_points_url eq ""} {
            reply $type $target "\002error:\002 API sent a redirect without a location."
            return
        }
        
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
