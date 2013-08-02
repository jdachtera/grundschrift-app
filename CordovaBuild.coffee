class CordovaBuild
  constructor: (@target, @options = [], @step = 'make') ->
  
  start: (callback) ->
    @log "prepare", "Reading config file"
    await fs.readFile "config.json", "utf-8", defer err, configJson
    @checkError err
    
    @conf = JSON.parse configJson
    @conf.cruft_dirs[k] = new RegExp(v) for v,k in @conf.cruft_dirs
    @conf.cruft_files[k] = new RegExp(v) for v,k in @conf.cruft_files
    
    @conf.sdk_dirs = @resolveHome @conf.sdk_dirs
    @conf.cordova_paths = @resolveHome @conf.cordova_paths
    @conf.build_dirs = @resolveHome @conf.build_dirs
    @conf.source_dirs = @resolveHome @conf.source_dirs
    
    process.env.PATH += ":" + [
      @conf.sdk_dirs.android + "tools",
      @conf.sdk_dirs.android + "platform-tools",
      @conf.sdk_dirs.webos + "bin"].join ":"
      
    @filename  = switch @target
      when 'android' then @conf.app.id + '_' + @conf.app.version + '.apk'
      when 'webos' then @conf.app.id + "_" + @conf.app.version + "_all.ipk"



    
    if @["#{@target}_#{@step}"]
      await @["#{@target}_#{@step}"] defer err
    else if @[@step]
      await @[@step] defer err
    
    
    callback()
    
  checkError: (err, stdout, stderr) =>
    if (err)
      console.error stderr || stdout || err
      throw "Error"

  ask: (question, callback) =>
    stdin = process.stdin
    stdout = process.stdout

    stdin.resume();
    stdout.write question + ": "

    stdin.once 'data', (data)->
      data = data.toString().trim()
      str = ''
      str.length = (question + ': ' + data.toString()).length
      stdout.write '\r' + str
      callback(data)
      
  resolveHome: (paths) ->
    paths[k] = path.split("~").join(process.env.HOME) for k,path of paths
    paths
  
  log: (tag, message) ->
    #process.stdout.write " " for i in [0..80]
    #process.stdout.write "\r"
    process.stdout.write "#{@target.toUpperCase()}: #{message}\n"
    
  prepare: (callback) =>

    await wrench.rmdirRecursive @conf.build_dirs[@target], defer err
    @log "prepare", "Deleted old build directory." if not err
    
    @log "prepare", "Copying source files to build directory."
    await wrench.copyDirRecursive "./src", @conf.build_dirs[@target], defer err
    @checkError err
    
    @log "prepare", "Reading phonegap version"
    await fs.readFile "#{@conf.source_dirs[@target]}/VERSION", "utf-8", defer err, contents
    if err
      await fs.readFile "#{@conf.source_dirs[@target]}/CordovaLib/VERSION", "utf-8", defer err, contents

    @checkError err
    @conf["cordova_version"] = contents.split('\n')[0]
    
    @log "prepare", "Copying cordova.js"
    # Try cordova.js first then cordova-x.x.x.js
    cordova_js = "#{@conf.cordova_paths[@target]}cordova.js"

    await fs.stat cordova_js, defer err, stats
    if err or not stats.isFile()
      cordova_js = "#{@conf.cordova_paths[@target]}cordova-#{@conf.cordova_version}.js"

    await fs.copy cordova_js, "#{@conf.build_dirs[@target]}/cordova.js", defer err
    @checkError err
    
    callback()
    
  build: (callback) =>
    for message, command of @conf.build_commands
      @log "build", message
      await exec command, {cwd: @conf.build_dirs[@target]}, defer err
      @checkError err
    
    callback()
    
  match: (str, exps) ->
    for exp in exps
      return true unless str.search(exp) is -1
    false
    
  decruft: (dir, depth, callback) =>
    @log "decruft", "Removing cruft" if depth is 0

    await fs.readdir dir, defer err, contents

    for entry in contents
      fullpath = dir + "/" + entry
      await fs.stat fullpath, defer err, stat

      if stat.isFile() and @match(fullpath, @conf.cruft_files)
        await fs.unlink fullpath, defer err

      else if stat.isDirectory()
        if @match(fullpath, @conf.cruft_dirs)
          await wrench.rmdirRecursive fullpath, defer err
        else
          await @decruft fullpath, depth + 1, defer err

    callback()
  
  debug: (callback) =>
    @log "debug", "Removing main.html"
    await fs.unlink "#{@conf.build_dirs[@target]}/main.html", defer err
    @checkError err
    
    @log "debug", "Renaming debug.html to main.html"
    await fs.rename "#{@conf.build_dirs[@target]}/debug.html", "#{@conf.build_dirs[@target]}/main.html", defer err
    @checkError err
    
    @log "debug", "Resolving network address"
    await dns.lookup os.hostname(), defer err, @address, fam
    @checkError err
    
    @log "debug", "Parsing main.html"
    await fs.readFile "#{@conf.build_dirs[@target]}/main.html", "utf-8", defer err, html
    await jsdom.env html, [], defer errors, window
    @checkError errors

    @log "debug", "Installing weinre"
    html = window.document.getElementsByTagName("head")[0].innerHTML
    html = '<script src="http://' + @address + ':8081/target/target-script-min.js#anonymous"></script>' + html
    window.document.getElementsByTagName("head")[0].innerHTML = html
    
    @log "debug", "Writing main.html"
    await fs.writeFile "#{@conf.build_dirs[@target]}/main.html", window.document._doctype._fullDT + window.document.outerHTML, defer err
    @checkError err
    
    
    callback()
  
    
  web: (callback) =>
    await @prepare defer errs
    
    if @options.indexOf("debug") == -1
      await @build defer err
      await @decruft @conf.build_dirs[@target], 0, defer err
    else
      await @debug defer err
      
    callback()
    
  make: (callback) ->
    await @[@target + '_build'] defer err
    await @[@target + '_install'] defer err
    await @[@target + '_log'] defer err
    
    callback()

  webos_build: (callback) ->
    @log "prepare", "Generating cordova.js"
    await exec "rm lib/cordova.js; make copy_js", { cwd: @conf.source_dirs['webos'] }, defer err, stdout, stderr
    @checkError err, stdout, stderr
    
    await @web defer err
    
    @log "package", "Reading default appinfo.json"
    await fs.readFile "#{@conf.cordova_paths[@target]}/appinfo.json", "utf-8", defer err, appinfoContent
    @checkError err

    @log "package", "Writing appinfo.json"
    appInfo = JSON.parse appinfoContent
    for k,v of @conf.app
      appInfo[k] = @conf.app[k]
    await fs.writeFile "#{@conf.build_dirs[@target]}/appinfo.json", JSON.stringify(appInfo, undefined, 2), defer err
    @checkError err
    
    @log "package", "Generating webos package"
    await exec "palm-package #{@conf.build_dirs[@target]}", { cwd: "./"}, defer err, stdout, stderr
    @checkError err, stdout, stderr
    
    @log "package", "Moving package into ./bin"
    await fs.rename "./#{@filename}", "./bin/#{@filename}", defer err
    @checkError err

    callback()
  
  webos_install: (callback) =>
    @log("INSTALL", "Installing package")
    await exec "palm-install ./bin/#{@filename}", defer err
    
    await @webos_launch defer err
    await @webos_log defer err
    @checkError
    
    callback()
  
  webos_launch: (callback) =>
    @log "LAUNCH", "Launching package"
    await exec "palm-launch #{@conf.app.id}", defer err
    @checkError err
    
    callback()
    
  webos_log: (callback) =>
    @log("LOGGER", "Logging console output")
    await exec "palm-log --system-log-level info", defer err
    log = spawn "palm-log", ["-f", @conf.app.id]
    log.stdout.setEncoding "utf8"
    log.stdout.on "data", (data) ->
      if data[0] == "["
          line = data.split(" ").slice(1).join(" ")
          type = line.split(": ")[0]
          rest = line.split(": ").slice(1).join(": ")
          message = rest.split(", ").slice(0,-1).join(", ")
          source = rest.split(", ").pop().split("\n")[0].split(":")
          if type== "info"
              console.log("WEBOS_LOG: " + clc.green(message) + " (" + source[0] + " Line: " + source[1] + ")")
          if type== "error"
              console.log("WEBOS_ERROR: " + clc.red(message) + " (" + source + ")")
  
  webos_repo: (callback) =>
    
    @log "repo", "Reading stats"
    await fs.stat "./bin/#{@filename}", defer err, stats
    @checkError err
    
    @log "repo", "Computing md5 sum"
    await exec "md5 -q ./bin/#{@filename}", defer err, md5
    @checkError err
    
    pkg =
      Package: @conf.app.id,
      Description: @conf.app.title,
      Version: @conf.app.version,
      Section: "misc",
      Architecture: "all",
      Maintainer: @conf.app.vendor,
      MD5Sum: md5.split("\n")[0],
      Size: stats.size,
      Filename: @filename,
      Source: JSON.stringify
        Title: @conf.app.title,
        License: @conf.app.license,
        Category: @conf.app.category,
        LastUpdated: Math.round(stats.ctime.getTime() / 1000),
        Location: "http://web303.webgo24-server13.de/gsrepo/#{@filename}",
        Type: "Application",
        Feed: @conf.app.id

    lines = []

    for key of pkg
        lines.push key + ": " + pkg[key]
        
    @log "repo", "Saving repo file"
    await fs.writeFile "./bin/Packages", lines.join("\n"), "utf-8", defer err
    @checkError err
    
    callback()
    
  
    
  android_build: (callback) =>
    await fs.exists "./build/android", defer exists
    if exists
      @log "prepare", "Reusing old Skeleton directory. Delete build/android to reset."
    else
      @log "prepare", "Generating Android App Skeleton"
      await exec "#{@conf.source_dirs[@target]}/bin/create build/android #{@conf.app.id} main", defer err, stdout, stderr
      @checkError err, stderr, stdout
      
      await fs.writeFile "./build/android/res/values/strings.xml",
          '<?xml version="1.0" encoding="utf-8"?>
          <resources>
              <string name="app_name">' + @conf.app.title + '</string>
          </resources>', defer err
      @checkError err
      
      @log "prepare", "Removing cordova icons"
      for n in ["hdpi", "mdpi", "ldpi", "xhdpi"]
        await fs.unlink "./build/android/res/drawable-#{n}/icon.png", defer err
        @checkError err
      
      @log "prepare", "Removing assets/www"
      await wrench.rmdirRecursive "./build/android/assets/www", defer err

    await fs.stat "./AndroidManifest.xml", defer err, stats
    if not err and stats.isFile()
      @log "prepare", "Copying custom AndroidManifest.xml"
      fs.createReadStream("./AndroidManifest.xml").pipe(fs.createWriteStream("./build/android/AndroidManifest.xml"));

    await @web defer err
    
    @log "PREPARE", "Moving Icon file"
    split = @conf.app.icon.split(".")
    ext = split.pop();
    basename = split.join('.')

    for n in ["hdpi", "mdpi", "ldpi", "xhdpi"]
      await fs.rename "#{@conf.build_dirs[@target]}/#{basename}-#{n}.#{ext}", "./build/android/res/drawable-#{n}/icon.png", defer err

    await fs.rename "#{@conf.build_dirs[@target]}/#{basename}.#{ext}", "./build/android/res/drawable/icon.png", defer err
    mode = "debug"

    await fs.stat './ant.properties', defer err, stats
    if not err and stats.isFile()
      fs.createReadStream("./ant.properties").pipe(fs.createWriteStream("./build/android/ant.properties"));
      mode = "release"

    @log "PACKAGE", "Creating package"
    await exec "ant " + mode, { cwd: "./build/android" }, defer err, stdout, stderr
    @checkError err, stdout, stderr
    
    @log "PACKAGE", "Moving package into ./bin"
    await fs.rename "./build/android/bin/main-" + mode + ".apk", "./bin/#{@filename}", defer err
    @checkError err
    
    callback()
    
  android_install: (callback) =>
    @log "INSTALL", "Installing package"
    await exec "adb install -r ./bin/#{@filename}", defer err, stdout, stderr
    @checkError err, stdout, stderr
    await @android_launch defer()
    await @android_log defer()
    callback()
    
  android_launch: (callback) =>
    @log "LAUNCH", "Launching app"
    await exec "adb shell am start -n #{@conf.app.id}/#{@conf.app.id}.main", defer err, stdout, stderr
    @checkError err, stdout, stderr
    console.log(stdout)

    callback()
    
  android_log: (callback) =>
    log = spawn "adb", ["logcat -s CordovaLog", @conf.app.id]
    log.stdout.setEncoding "utf8"

    # Hack the important messages out of the log junk
    log.stdout.on "data", (data) ->
      lines = data.split("\r\n")
      for line in lines
        parts = line.split ": "
        if parts.length > 2
          number = parts[2].split(" ")[1]
          file = parts[1].split("file:///android_asset/www/").pop()
          if line.search(/Error.+/) > -1
            console.log("ANDROID_ERROR: " + clc.red(parts.slice(4).join(": ")) + " (" + file +  " Line: " + number + ")")
          else if number
                  console.log("ANDROID_LOG: " + clc.green(parts[3]) + " (" + file + " Line: " + number + ")")
    callback()


  ios_build: (callback) =>
    await fs.exists "./build/ios", defer exists
    if exists
      @log "prepare", "Reusing old Skeleton directory. Delete build/ios to reset."
    else
      @log "prepare", "Generating IOS App Skeleton"
      await exec "#{@conf.source_dirs[@target]}/bin/create build/ios #{@conf.app.id} #{@conf.app.title}", defer err, stdout, stderr
      @checkError err, stderr, stdout

      @log "prepare", "Removing /www"
      await wrench.rmdirRecursive "./build/ios/www", defer err

    await @web defer err


    callback()

  ios_install: (callback) =>
    @log "INSTALL", "Install package via Xcode!"
    callback()

  ios_launch: (callback) =>
    @log "LAUNCH", "Launch project via Xcode!"
    #exec "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Applications/iPhone\\ Simulator.app/Contents/MacOS/iPhone\\ Simulator -SimulateApplication package"

    callback()

  ios_log: (callback) =>
    @log "INSTALL", "Log app via Xcode!"
    callback()


  w8_build: (callback) =>
    await fs.exists "./build/windows8", defer exists
    if exists
      @log "prepare", "Reusing old Skeleton directory. Delete build/windows8 to reset."
    else
      @log "prepare", "Generating IOS App Skeleton"
      await exec "#{@conf.source_dirs[@target]}/bin/create.bat build/windows8 #{@conf.app.id} #{@conf.app.title}", defer err, stdout, stderr
      @checkError err, stderr, stdout

      @log "prepare", "Removing /www"
      await wrench.rmdirRecursive "./build/ios/www", defer err

    await @web defer err


    callback()

  w8_install: (callback) =>
    @log "INSTALL", "Install package via Visual Studio!"
    callback()

  w8_launch: (callback) =>
    @log "LAUNCH", "Launch project via Visual Studio!"
    #exec "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Applications/iPhone\\ Simulator.app/Contents/MacOS/iPhone\\ Simulator -SimulateApplication package"

    callback()

  w8_log: (callback) =>
    @log "INSTALL", "Log app via Visual Studio!"
    callback()



                    
exec = require("child_process").exec
spawn = require("child_process").spawn
os = require "os"
dns = require "dns"

target = process.argv[3]
step = process.argv[2]

targets = [
  'web'
  'webos'
  'android',
  'ios',
]

steps = [
  'build'
  'install'
  'log',
  'make'
]

options = [
  'debug'
]

b = (target, step, callback) ->
   build = new CordovaBuild target, process.argv.slice(4), step
   
   await build.start defer err
   console.log "All finished."
   callback(err)

try
  fs = require "fs-extra"
  wrench = require "wrench"
  less = require "less"
  clc = require "cli-color"
  cleanCSS = require "clean-css"
  jsdom = require "jsdom"
  if target in targets
    await b target, step, defer err
    
  else if not target || target == "all"
    for target in ["webos", "android"]
      await b target, step, defer err
  else
    console.log "USAGE: node CordovaBuild [#{options.join(",")}] [#{targets.join("|")}] [#{steps.join("|")}|all]"
    console.log "USAGE: A call without arguments is equal to \"node CordovaBuild all all\""

catch error
  if error.code is "MODULE_NOT_FOUND"
    console.log "There are missing modules. Installing..."
    await exec "npm install", defer err, stdout, stderr
    if err
      console.log stderr
    console.log "Install Finished. Now run the script again"
  
  
