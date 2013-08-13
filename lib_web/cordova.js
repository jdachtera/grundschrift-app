// Cordova Browser Fallback
var device = {
    platform: "browser"
};



window.setTimeout(function() {
    var e = document.createEvent('Events');
    e.initEvent("deviceready", true, true);
    document.dispatchEvent(e);
}, 250);

