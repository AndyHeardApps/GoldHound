-- GoldHound: charts drawn from lines and textures. Each chart keeps pools of
-- lines, boxes and labels that are reused on every draw, and shows a tooltip
-- for the data point nearest the cursor.
local ADDON, ns = ...
local Chart = {}
ns.Chart = Chart

local PAD = { left = 72, right = 16, top = 14, bottom = 24 }
local GRID = 4

-- "12,345g", "8.5g", "40s" or "7c": short money for axis labels.
function Chart.ShortMoney(copper)
  copper = math.floor((tonumber(copper) or 0) + 0.5)
  local sign = copper < 0 and "-" or ""
  copper = math.abs(copper)
  if copper >= 10000 then
    local g = copper / 10000
    local text
    if g >= 100 then
      text = ("%d"):format(math.floor(g + 0.5))
      text = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
      text = text:gsub("^,", "")
    else
      text = ("%.1f"):format(g)
      text = text:gsub("%.0$", "")
    end
    return sign .. text .. "g"
  elseif copper >= 100 then
    return sign .. ("%d"):format(math.floor(copper / 100)) .. "s"
  end
  return sign .. copper .. "c"
end

local function NiceMax(v)
  if not v or v <= 0 then return 1 end
  local mag = 10 ^ math.floor(math.log10(v))
  for _, m in ipairs({ 1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10 }) do
    if m * mag >= v then return m * mag end
  end
  return 10 * mag
end

-------------------------------------------------------------------------------
-- Element pools
-------------------------------------------------------------------------------
local function Acquire(pool, create)
  pool.n = pool.n + 1
  local obj = pool[pool.n]
  if not obj then
    obj = create()
    pool[pool.n] = obj
  end
  obj:Show()
  return obj
end

local function Reset(c)
  for _, pool in pairs(c.pools) do
    for i = 1, pool.n do pool[i]:Hide() end
    pool.n = 0
  end
  c.hit = nil
  c.cursor:Hide()
end

-- All coordinates are pixels from the chart's bottom-left corner.
local function Box(c, x, y, w, h, r, g, b, a)
  local t = Acquire(c.pools.boxes, function() return c:CreateTexture(nil, "ARTWORK") end)
  t:ClearAllPoints()
  t:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", x, y)
  t:SetSize(math.max(w, 1), math.max(h, 1))
  t:SetColorTexture(r, g, b, a or 1)
  return t
end

local function Line(c, x1, y1, x2, y2, r, g, b, a, thickness)
  if not c.CreateLine then
    Box(c, x2 - 1, y2 - 1, 3, 3, r, g, b, a)
    return
  end
  local l = Acquire(c.pools.lines, function() return c:CreateLine(nil, "ARTWORK", nil, 1) end)
  l:SetStartPoint("BOTTOMLEFT", c, x1, y1)
  l:SetEndPoint("BOTTOMLEFT", c, x2, y2)
  l:SetThickness(thickness or 2)
  l:SetColorTexture(r, g, b, a or 1)
  return l
end

local function Label(c, text, x, y, anchor, r, g, b)
  local f = Acquire(c.pools.labels, function() return c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") end)
  f:ClearAllPoints()
  f:SetPoint(anchor or "LEFT", c, "BOTTOMLEFT", x, y)
  f:SetText(text or "")
  f:SetTextColor(r or 0.8, g or 0.8, b or 0.8)
  return f
end

-------------------------------------------------------------------------------
-- Chart frames
-------------------------------------------------------------------------------
local function PlotSize(c)
  return c.width - PAD.left - PAD.right, c.height - PAD.top - PAD.bottom
end

local function Track(c)
  if not c.hit then return end
  local scale = c:GetEffectiveScale()
  local cx = GetCursorPosition() / scale - (c:GetLeft() or 0)
  local snapX, title, lines = c.hit(cx - PAD.left)
  if not snapX then
    c.cursor:Hide()
    GameTooltip:Hide()
    return
  end
  local _, ph = PlotSize(c)
  c.cursor:ClearAllPoints()
  c.cursor:SetPoint("BOTTOM", c, "BOTTOMLEFT", PAD.left + snapX, PAD.bottom)
  c.cursor:SetHeight(ph)
  c.cursor:Show()
  GameTooltip:SetOwner(c.hover, "ANCHOR_CURSOR")
  GameTooltip:SetText(title or "")
  for _, l in ipairs(lines or {}) do GameTooltip:AddDoubleLine(l[1], l[2], 0.8, 0.8, 0.8, 1, 1, 1) end
  GameTooltip:Show()
end

function Chart.New(parent, width, height)
  local c = CreateFrame("Frame", nil, parent)
  c:SetSize(width, height)
  c.width, c.height = width, height
  c.pools = { lines = { n = 0 }, boxes = { n = 0 }, labels = { n = 0 } }
  local bg = c:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(1, 1, 1, 0.025)
  c.cursor = c:CreateTexture(nil, "OVERLAY")
  c.cursor:SetColorTexture(1, 1, 1, 0.3)
  c.cursor:SetWidth(1)
  c.cursor:Hide()
  c.empty = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  c.empty:SetPoint("CENTER")
  c.empty:SetWidth(width - 40)
  c.empty:SetJustifyH("CENTER")
  local pw, ph = PlotSize(c)
  c.hover = CreateFrame("Frame", nil, c)
  c.hover:SetPoint("BOTTOMLEFT", PAD.left, PAD.bottom)
  c.hover:SetSize(pw, ph)
  c.hover:EnableMouse(true)
  c.hover:SetScript("OnEnter", function(self) self:SetScript("OnUpdate", function() Track(c) end) end)
  c.hover:SetScript("OnLeave", function(self)
    self:SetScript("OnUpdate", nil)
    c.cursor:Hide()
    GameTooltip:Hide()
  end)
  return c
end

-- Gridlines, axis lines, money labels on the left and the given x labels.
local function Axes(c, ymax, xLabels, format)
  local pw, ph = PlotSize(c)
  Box(c, PAD.left, PAD.bottom, 1, ph, 1, 1, 1, 0.35)
  Box(c, PAD.left, PAD.bottom, pw, 1, 1, 1, 1, 0.35)
  for i = 0, GRID do
    local y = PAD.bottom + ph * i / GRID
    if i > 0 then Box(c, PAD.left, y, pw, 1, 1, 1, 1, 0.07) end
    Label(c, format(ymax * i / GRID), PAD.left - 6, y, "RIGHT")
  end
  for _, l in ipairs(xLabels) do
    Box(c, l.x, PAD.bottom - 3, 1, 3, 1, 1, 1, 0.35)
    Label(c, l.text, l.x, PAD.bottom - 12, "CENTER")
  end
end

local function TimeFormat(span)
  if span >= 3 * 86400 then return "%d %b" end
  if span >= 86400 then return "%d %b %H:%M" end
  return "%H:%M"
end

-- Averages runs of points so at most `max` remain. Points are { t, v }.
local function Downsample(points, max)
  local n = #points
  if n <= max then return points end
  local size = math.ceil(n / max)
  local out = {}
  for i = 1, n, size do
    local st, sv, k = 0, 0, 0
    for j = i, math.min(i + size - 1, n) do
      st, sv, k = st + points[j][1], sv + points[j][2], k + 1
    end
    table.insert(out, { st / k, sv / k })
  end
  return out
end

local function Nearest(points, t)
  local best, bestD
  for _, p in ipairs(points) do
    local d = math.abs(p[1] - t)
    if not best or d < bestD then best, bestD = p, d end
  end
  return best
end

-- Overlapping lines over time.
-- series: { { name, color = { r, g, b }, points = { { t, value }, ... } sorted by t }, ... }
-- opts: empty (text when nothing to draw), format (value -> text), extra(t, lines) adds tooltip lines.
function Chart.DrawLines(c, series, opts)
  Reset(c)
  opts = opts or {}
  local format = opts.format or Chart.ShortMoney
  local pw, ph = PlotSize(c)
  local xmin, xmax, ymax = math.huge, -math.huge, 0
  for _, s in ipairs(series) do
    for _, p in ipairs(s.points) do
      if p[1] < xmin then xmin = p[1] end
      if p[1] > xmax then xmax = p[1] end
      if p[2] > ymax then ymax = p[2] end
    end
  end
  if xmax == -math.huge then
    c.empty:SetText(opts.empty or "No data yet.")
    return
  end
  c.empty:SetText("")
  if xmax - xmin < 3600 then xmax = xmin + 3600 end
  ymax = NiceMax(ymax * 1.05)
  local function X(t) return PAD.left + (t - xmin) / (xmax - xmin) * pw end
  local function Y(v) return PAD.bottom + math.max(0, math.min(1, v / ymax)) * ph end

  local labels, fmt = {}, TimeFormat(xmax - xmin)
  for i = 0, 4 do
    local t = xmin + (xmax - xmin) * i / 4
    table.insert(labels, { x = X(t), text = date(fmt, math.floor(t)) })
  end
  Axes(c, ymax, labels, format)

  local maxPoints = math.max(10, math.floor(pw / 3))
  local lx = PAD.left + 10
  local ly = PAD.bottom + ph - 10
  for _, s in ipairs(series) do
    local r, g, b = s.color[1], s.color[2], s.color[3]
    local pts = Downsample(s.points, maxPoints)
    s.drawn = pts
    for i = 2, #pts do
      Line(c, X(pts[i - 1][1]), Y(pts[i - 1][2]), X(pts[i][1]), Y(pts[i][2]), r, g, b, 1, 2)
    end
    if #pts == 1 then Box(c, X(pts[1][1]) - 2, Y(pts[1][2]) - 2, 4, 4, r, g, b, 1) end
    Box(c, lx, ly, 12, 3, r, g, b, 1)
    local lab = Label(c, s.name, lx + 16, ly + 1, "LEFT", 1, 1, 1)
    lx = lx + 16 + (lab:GetStringWidth() or 40) + 18
  end

  c.hit = function(px)
    if px < -4 or px > pw + 4 then return nil end
    local t = xmin + (px / pw) * (xmax - xmin)
    local best
    for _, s in ipairs(series) do
      local p = Nearest(s.drawn, t)
      if p and (not best or math.abs(p[1] - t) < math.abs(best - t)) then best = p[1] end
    end
    if not best then return nil end
    local lines = {}
    for _, s in ipairs(series) do
      local p = Nearest(s.drawn, best)
      if p then table.insert(lines, { s.name, format(p[2]) }) end
    end
    if opts.extra then pcall(opts.extra, best, lines) end
    return X(best) - PAD.left, date("%d %b %Y %H:%M", math.floor(best)), lines
  end
end

-- Price spread over time as filled bands: a grey area from the lowest to the
-- highest listing, a blue area from the 25th to the 75th percentile on top of
-- it, a white median line and a yellow mean line, with a dot at each
-- observation. Textures are the only filled shape available, so each band is
-- built from narrow vertical strips interpolated between observations. The
-- scale ignores wild outliers; a red tick at the top marks a clipped high.
-- points: { { t, min, p25, med, p75, max, mean, qty, n }, ... } sorted by t
local STRIP = 2

local function Band(c, X, Y, points, loKey, hiKey, r, g, b, a)
  local n = #points
  local function at(p, key) return p[key] or p.min or 0 end
  if n == 1 then
    local p = points[1]
    local x, ylo, yhi = X(p.t), Y(at(p, loKey)), Y(at(p, hiKey))
    Box(c, x - 3, ylo, 6, math.max(1, yhi - ylo), r, g, b, a)
    return
  end
  local x, xEnd = X(points[1].t), X(points[n].t)
  local i = 1
  while x < xEnd do
    local xe = math.min(x + STRIP, xEnd)
    local xm = (x + xe) / 2
    while i < n - 1 and X(points[i + 1].t) <= xm do i = i + 1 end
    local p, q = points[i], points[i + 1]
    local xp, xq = X(p.t), X(q.t)
    local f = xq > xp and (xm - xp) / (xq - xp) or 0
    f = math.max(0, math.min(1, f))
    local lo = at(p, loKey) + (at(q, loKey) - at(p, loKey)) * f
    local hi = at(p, hiKey) + (at(q, hiKey) - at(p, hiKey)) * f
    local ylo, yhi = Y(lo), Y(hi)
    if yhi - ylo >= 0.5 then Box(c, x, ylo, xe - x, yhi - ylo, r, g, b, a) end
    x = xe
  end
end

local function Polyline(c, X, Y, points, key, r, g, b, a, thickness, dot)
  local prevX, prevY
  for _, p in ipairs(points) do
    local v = p[key]
    if v then
      local x, y = X(p.t), Y(v)
      if prevX then Line(c, prevX, prevY, x, y, r, g, b, a, thickness) end
      if dot then Box(c, x - dot / 2, y - dot / 2, dot, dot, r, g, b, a) end
      prevX, prevY = x, y
    else
      prevX = nil
    end
  end
end

function Chart.DrawBands(c, points, opts)
  Reset(c)
  opts = opts or {}
  local format = opts.format or Chart.ShortMoney
  local pw, ph = PlotSize(c)
  local n = #points
  if n == 0 then
    c.empty:SetText(opts.empty or "No data yet.")
    return
  end
  c.empty:SetText("")
  local top = 0
  for _, p in ipairs(points) do
    local body = math.max(p.p75 or 0, p.mean or 0, p.med or 0, p.min or 0)
    if body > top then top = body end
  end
  for _, p in ipairs(points) do
    -- Include the highest listing unless it is wildly above the body of the market.
    if p.max and p.max <= top * 2 and p.max > top then top = p.max end
  end
  local ymax = NiceMax(top * 1.08)
  local tmin, tmax = points[1].t or 0, points[n].t or 0
  local span = tmax - tmin
  if span < 3600 then span = 3600 end
  local margin = span * 0.03
  local xmin, xmax = tmin - margin, tmax + margin
  local function X(t) return PAD.left + ((t or 0) - xmin) / (xmax - xmin) * pw end
  local function Y(v) return PAD.bottom + math.max(0, math.min(1, (v or 0) / ymax)) * ph end

  local labels, fmt = {}, TimeFormat(xmax - xmin)
  local ticks = math.max(2, math.min(6, math.floor(pw / 110)))
  for i = 0, ticks do
    local t = xmin + (xmax - xmin) * i / ticks
    table.insert(labels, { x = X(t), text = date(fmt, math.floor(t)) })
  end
  Axes(c, ymax, labels, format)

  Band(c, X, Y, points, "min", "max", 0.75, 0.75, 0.75, 0.22)
  Band(c, X, Y, points, "p25", "p75", 0.3, 0.6, 1, 0.5)
  Polyline(c, X, Y, points, "mean", 1, 0.82, 0.2, 0.9, 1.5)
  Polyline(c, X, Y, points, "med", 1, 1, 1, 1, 2, 3)
  for _, p in ipairs(points) do
    if p.max and p.max > ymax then Box(c, X(p.t) - 3, PAD.bottom + ph - 1, 6, 2, 1, 0.3, 0.3, 1) end
  end

  c.hit = function(px)
    if px < -4 or px > pw + 4 then return nil end
    local t = xmin + (px / pw) * (xmax - xmin)
    local i, bestD = 1, math.huge
    for j, p in ipairs(points) do
      local d = math.abs((p.t or 0) - t)
      if d < bestD then i, bestD = j, d end
    end
    local p = points[i]
    local lines = {
      { "Lowest", format(p.min) },
      { "25th percentile", format(p.p25 or p.min) },
      { "Median", format(p.med or p.min) },
      { "Mean", format(p.mean or p.min) },
      { "75th percentile", format(p.p75 or p.min) },
      { "Highest", format(p.max or p.min) },
      { "Units listed", tostring(p.qty or "?") },
      { "Listings", tostring(p.n or "?") },
    }
    return X(p.t) - PAD.left, date("%d %b %Y %H:%M", p.t or 0), lines
  end
end
