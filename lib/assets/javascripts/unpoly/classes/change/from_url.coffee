#= require ./change

u = up.util

class up.Change.FromURL extends up.Change

  constructor: (options) ->
    super(options)

    @successOptions = u.copy(@options)
    @successOptions.inspectResponse = @fullLoad
    @deriveFailOptions()

  # These options are used before the request is sent.
  # Hence there is no failVariant.
  @PREFLIGHT_KEYS: [
    'base',
    'inspectResponse',
    'url',
    'method',
    'origin',
    'headers',
    'params',
    'cache',
    'solo',
    'confirm',
    'feedback',
    'origin',
    'hungry'
  ]

  deriveFailOptions: ->
    # `successOptions` is an object like
    #
    #     { foo: 1, failFoo: undefined, bar: 2, failBar: 3, baz: 4 }
    #
    # We want to use the failVariant keys where they exists and are defined.
    # Hence the result should be:
    #
    #     { foo: 1, bar: 3, baz: 4 }
    #
    # Note how we *don't* override `foo` with `undefined`.
    mode = @successOptions.failOptions || 'explicit'

    switch mode
      when 'explicit'
        # In explicit mode the developer needs to pass all failVariant
        # keys that should be used for failed responses. From the succcess options
        # we only inherit keys that need to be known before the request goes out,
        # like { method }, { url } or { params }.
        preflightOptions = u.pick(@successOptions, @constructor.PREFLIGHT_KEYS)
        @failOptions = u.merge(preflightOptions, @explicitFailOptions())
      when 'inherit'
        # In inherit mode all success options are copied and can then be
        # overridden with failVariant keys.
        @failOptions = u.merge(@successOptions, @explicitFailOptions())
      when 'mirror'
        # In mirror mode we use the same options for fail that we use for success,
        # ignoring all failVariant keys.
        # This is useful for up.validate(), where we want to always use the form's
        # success options regardless of the response status.
        @failOptions = u.copy(@successOptions)

  explicitFailOptions: ->
    opts = {}
    for key, value of @successOptions
      # Only add a key/value pair if there is a defined failOverride.
      # The condition below looks wrong at first, but really isn't. Be aware that
      # up.fragment.successKey(key) only returns a value if the given key is prefixed with
      # "fail"!
      if unprefixedKey = up.fragment.successKey(key)
        failValue = @successOptions[key]
        # up.OptionParser sets keys to undefined, even if neither options nor element
        # produces that option. Hence we ignore undefined values. To override it with
        # an empty value, the developer needs to pass null instead.
        if u.isDefined(failValue)
          opts[unprefixedKey] = failValue
    return opts

  execute: ->
    if !up.browser.canPushState() && @successOptions.history != false
      @fullLoad() unless @successOptions.preload
      return u.unresolvablePromise()

    @buildRequest()

    promise = up.request(@request)
    unless @successOptions.preload
      promise = promise.then(@onRequestSuccess, @onRequestFailure)
    return promise

  buildRequest: ->
    successPreview = new up.Change.FromContent(@successOptions)
    failPreview = new up.Change.FromContent(@failOptions)

    requestAttrs = u.merge(
      @successOptions,
      successPreview.requestAttributes(),
      u.renameKeys(failPreview.requestAttributes(optional: true), up.fragment.failKey)
    )

    @request = new up.Request(requestAttrs)

  onRequestSuccess: (response) =>
    up.puts('Updating page with successful response')
    @processResponse(response, @successOptions)

  onRequestFailure: (response) =>
    rejectWithFailedResponse = -> Promise.reject(response)
    if @failedResponseHasContent(response)
      up.puts('Updating page with failed response')
      promise = @processResponse(response, @failOptions)
      # Although processResponse() will fulfill with a successful replacement of options.failTarget,
      # we still want to reject the promise that's returned to our API client.
      return u.always(promise, rejectWithFailedResponse)
    else
      up.puts('Response failed without content')
      return rejectWithFailedResponse()

  processResponse: (response, options) ->
    @augmentOptionsFromResponse(response, options)

    # Allow listeners to
    loadedEvent = up.event.build('up:fragment:loaded', { change: options, response: response })
    promise = response.request.whenEmitted(loadedEvent, callback: options.onLoaded)
    promise = promise.then -> new up.Change.FromContent(options).execute()
    promise

  augmentOptionsFromResponse: (response, options) ->
    options.html = response.text

    responseURL = response.url
    locationFromExchange = responseURL

    if hash = @request.hash
      options.hash = hash
      locationFromExchange += hash

    isReloadable = (response.method == 'GET')

    if isReloadable
      # Remember where we got the fragment from so we can up.reload() it later.
      options.source = @improveHistoryValue(options.source, responseURL)
    else
      # Keep the source of the previous fragment (e.g. the form that was submitted into failure).
      options.source = @improveHistoryValue(options.source, 'keep')
      # Since the current URL is not retrievable over the GET-only address bar,
      # we can only provide history if a location URL is passed as an option.
      options.history = !!options.location

    options.location = @improveHistoryValue(options.location, locationFromExchange)
    options.title = @improveHistoryValue(options.title, response.title)
    options.acceptLayer = response.acceptLayer
    options.dismissLayer = response.dismissLayer
    options.eventPlans = response.eventPlans

  # Values we want to keep:
  # - false (no update)
  # - string (forced update)
  # Values we want to override:
  # - true (do update with defaults)
  # - missing (do with defaults)
  improveHistoryValue: (value, newValue) ->
    if value == false || u.isString(value)
      value
    else
      newValue

  failedResponseHasContent: (response) ->
    # Check if the failed response wasn't cause by a fatal error
    # like a timeout or disconnect.
    (response instanceof up.Response) && !response.fatal

  fullLoad: =>
    up.browser.loadPage(@successOptions.url, u.pick(@successOptions, ['method', 'params']))
