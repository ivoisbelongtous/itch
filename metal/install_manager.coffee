
app = require "app"
path = require "path"
fs = require "fs"

request = require "request"
progress = require "request-progress"
fstream = require "fstream"
mkdirp = require "mkdirp"
Humanize = require "humanize-plus"

keyMirror = require "keymirror"

defer = require "./defer"
fileutils = require "./fileutils"
api = require "./api"
db = require "./db"

AppDispatcher = require "./dispatcher/AppDispatcher"
AppConstants = require "./constants/AppConstants"
AppActions = require "./actions/AppActions"
AppStore = require "./stores/AppStore"

InstallState = keyMirror {
  PENDING: null
  SEARCHING_UPLOAD: null
  DOWNLOADING: null
  EXTRACTING: null
  CONFIGURING: null
  RUNNING: null
  ERROR: null
  IDLE: null
}

class AppInstall
  @library_dir: path.join(app.getPath("home"), "Downloads", "itch.io")
  @archives_dir: path.join(@library_dir, "archives")
  @apps_dir: path.join(@library_dir, "apps")

  constructor: ->
    # muffin

  setup: (opts) ->
    data = {
      _table: 'installs'
      game_id: opts.game.id
      state: InstallState.PENDING
    }
    db.insert(data).then (record) => @load(record)

  load: (record) ->
    @id = record._id
    @game_id = record.game_id
    @progress = 0

    db.findOne(_table: 'games', id: @game_id).then((game) =>
      @game = game or throw new Error "game not found: #{@game_id}"
      console.log "found game: #{JSON.stringify @game}"
    ).then(=>
      @app_path or db.findOne(_table: 'users', id: @game.user_id).then((user) =>
        console.log "found user: #{JSON.stringify user}"
        username = user.username
        slug = @game.url.match /[^\/]+$/
        @app_path = path.join(AppInstall.apps_dir, "#{slug}-by-#{username}")
      )
    ).then(=>
      @set_state record.state
      console.log "Loaded install #{@id} with state #{@state}"

      switch @state
        when InstallState.PENDING
          defer => @start()
    )

  set_state: (state) ->
    console.log "Install #{@id}, [#{@state} -> #{state}]"
    @state = state
    @emit_change()

  emit_change: ->
    defer => AppActions.install_progress @

  start: ->
    @search_for_uploads()

  search_for_uploads: ->
    @set_state InstallState.SEARCHING_UPLOAD

    client = AppStore.get_current_user()
    call = if @game.key
      client.download_key_uploads @game.key.id
    else
      client.game_uploads @game.id

    call.then (res) =>
      { uploads } = res
      console.log "Got uploads:\n#{JSON.stringify(uploads)}"

      # filter uploads to find one relevant to our current platform
      prop = switch process.platform
        when "darwin" then "p_osx"
        when "win32" then "p_windows"
        when "linux" then "p_linux"

      interesting_uploads = uploads.filter (upload) -> !!upload[prop]

      if interesting_uploads.length
        # TODO let user choose
        @set_upload interesting_uploads[0]
      else
        @set_state InstallState.ERROR
        AppActions.notify "No uploads found for #{@game.title}"

  set_upload: (@upload) ->
    console.log "Choosing to download #{@upload.filename}"

    ext = fileutils.ext @upload.filename
    archive_name = "upload-#{@upload.id}#{ext}"
    @archive_path = path.join(AppInstall.archives_dir, archive_name)
    @get_url()

  get_url: ->
    @set_state InstallState.DOWNLOADING

    client = AppStore.get_current_user()
    call = if @game.key
      client.download_upload_with_key @game.key.id, @upload.id
    else
      client.download_upload @upload.id

    call.then (res) =>
      @url = res.url
      defer => @download()

  download: ->
    @set_state InstallState.DOWNLOADING

    headers = {}
    flags = 'w'

    if @local_size
      headers['Range'] = "bytes=#{@local_size}-"
      flags = 'a'
    else if fs.existsSync(@archive_path)
      console.log "Have existing archive at #{@archive_path}, checking size"
      request.head(@url).on 'response', (response) =>
        content_length = response.headers['content-length']
        stats = fs.lstatSync @archive_path
        console.log "#{Humanize.fileSize content_length} (remote file size)"
        console.log "#{Humanize.fileSize stats.size} (local file size)"
        diff = content_length - stats.size

        if diff > 0
          console.log "Should download remaining #{Humanize.fileSize(diff)} bytes."
          @local_size = stats.size
          @get_url()
        else
          console.log "All good."
          @extract()

      return

    console.log "Downloading with headers #{JSON.stringify headers}, flags = #{flags}"
    r = progress request.get({
      url: @url
      headers
    }), throttle: 25
    r.on 'response', (response) =>
      console.log "Got status code: #{response.statusCode}"
      content_length = response.headers['content-length']
      console.log "Downloading #{Humanize.fileSize content_length} for #{@game.title}"

    r.on 'progress', (state) =>
      @progress = 0.01 * state.percent
      @emit_change()

    mkdirp.sync(path.dirname(@archive_path))
    dst = fs.createWriteStream(@archive_path, {
      flags
      defaultEncoding: "binary"
    })
    r.pipe(dst).on 'close', =>
      @progress = 0
      @emit_change()

      AppActions.bounce()
      AppActions.notify "#{@game.title} finished downloading."
      @extract()

  extract: ->
    @set_state InstallState.EXTRACTING

    require("./extractor").extract(@archive_path, @app_path).progress((state) =>
      console.log "Progress callback! #{state.percent}"
      @progress = 0.01 * state.percent
      @emit_change()
    ).then((res) =>
      @progress = 0
      @emit_change()
      console.log "Extracted #{res.total_size} bytes total"
      defer => @configure()
    ).catch (e) =>
      @set_state InstallState.ERROR
      console.log e
      AppActions.notify "Failed to extract #{@game.title}"

  configure: ->
    @set_state InstallState.CONFIGURING
    require("./configurator").configure(@app_path).then((res) =>
      @executables = res.executables
      if @executables.length > 0
        console.log "Configuration successful"
        defer => @launch()
      else
        @set_state InstallState.ERROR
        console.log "No executables found"
        AppActions.notify "Failed to configure #{@game.title}"
    )

  launch: ->
    @set_state InstallState.RUNNING
    require("./launcher").launch(@executables[0]).then((res) =>
      console.log res
      AppActions.notify res
    ).catch((e) =>
      msg = "#{@game.title} crashed with code #{e.code}"
      console.log msg
      console.log "...executable path: #{e.exe_path}"
      AppActions.notify msg
    ).finally(=>
      @set_state InstallState.IDLE
    )

install = ->
  AppDispatcher.register (action) ->
    switch action.action_type
      when AppConstants.DOWNLOAD_QUEUE
        install = new AppInstall()
        install.setup(action.opts)

      when AppConstants.LOGIN_DONE
        # load existing installs
        db.find(_table: 'installs').then((records) ->
          for record in records
            install = new AppInstall()
            install.load(record)
        )

module.exports = { install }

