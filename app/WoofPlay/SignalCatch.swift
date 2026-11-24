import SwiftUI

/// Signal Catch, the game on Explore while offline: drag the pup to catch falling Wi-Fi bars and dodge clouds.
/// 100 points in 30 seconds wins a bone and a lick on the screen; anything less, and the pup sobs.
struct SignalCatchCard: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var game = SignalCatchGame()
    @State private var isVisible = false

    /// The field stretches to fill the page; below this it's too short to see things fall.
    private static let minFieldHeight: CGFloat = 220
    private static let radius: CGFloat = 18
    private static let space = "signalCatch"
    /// How far past the card's top and right edges the confetti can fly.
    private static let confettiRoom = CGSize(width: Layout.screenPadding, height: 300)

    var body: some View {
        TimelineView(.animation(paused: !isVisible)) { timeline in
            let time = game.advance(to: timeline.date)
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    hud
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, Layout.chipSpacing)
                field(time: time)
            }
            .background(Color(.systemGray6))
            .clipShape(.rect(cornerRadius: Self.radius, style: .continuous))
            .coordinateSpace(.named(Self.space))
            // After the clip, so the confetti can fly out of the card.
            .overlay(alignment: .topLeading) { confetti }
        }
        // The pup's greys are drawn for a dark card, as on the Woof apps' offline badge in dark mode.
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, Layout.screenPadding)
        .padding(.bottom, Layout.sectionGap)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }

    private var header: some View {
        HStack {
            Text("Signal Catch")
                .font(.title3.weight(.heavy))
            Spacer()
            Text("Best \(game.best)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                BoneShape().fill(.primary).frame(width: 16, height: 16)
                Text("\(game.bones)").font(.subheadline.weight(.bold))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(game.bones) bones")
        }
        .monospacedDigit()
    }

    private var hud: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(Color(.systemGray4))
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(settings.accentColor)
                            .frame(width: proxy.size.width * min(1, Double(game.score) / Double(SignalCatchGame.goal)))
                    }
                }
                .frame(height: 8)
                .animation(.smooth(duration: 0.2), value: game.score)
                .onGeometryChange(for: CGPoint.self) { proxy in
                    let frame = proxy.frame(in: .named(Self.space))
                    return CGPoint(x: frame.maxX, y: frame.midY)
                } action: { game.confettiOrigin = $0 }
            if game.multiplier > 1 {
                Text("×\(game.multiplier)")
                    .font(.footnote.weight(.heavy))
                    .foregroundStyle(settings.accentColor)
            }
            Text("\(game.score)")
                .font(.subheadline.weight(.heavy))
            Text("\(Int(game.timeLeft.rounded(.up)))s")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(game.score) of \(SignalCatchGame.goal) points, \(Int(game.timeLeft.rounded(.up))) seconds left")
    }

    private func field(time: Double) -> some View {
        Canvas { context, size in
            game.size = size
            game.draw(in: context, time: time, accent: settings.accentColor)
        }
        .frame(minHeight: Self.minFieldHeight, maxHeight: .infinity)
        // Only while playing, so a swipe on the field still scrolls the page otherwise.
        .gesture(
            DragGesture(minimumDistance: 0).onChanged { game.aim(at: $0.location.x) },
            including: game.state == .play ? .all : .subviews
        )
        .accessibilityLabel("Drag left and right to move the pup")
        .overlay {
            if game.state == .idle || game.showsResult {
                result.transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: game.showsResult)
    }

    private var result: some View {
        VStack(spacing: 6) {
            switch game.state {
            case .win:
                Text("Full signal!").font(.system(size: 34, weight: .heavy))
                HStack(spacing: 6) {
                    BoneShape().fill(.primary).frame(width: 20, height: 20)
                    Text("+1 bone")
                }
                .font(.subheadline.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(.systemGray4), in: .capsule)
                Text("\(game.score) points. Good dog.")
                    .foregroundStyle(.secondary)
            case .lose:
                Text("\(game.score)").font(.system(size: 34, weight: .heavy)).monospacedDigit()
                Text("\(SignalCatchGame.goal - game.score) more for full signal. The pup believes in you.")
                    .foregroundStyle(.secondary)
            default:
                Text("No signal?").font(.system(size: 34, weight: .heavy))
                Text("Help the pup sniff some out. Drag to move, catch the bars, dodge the clouds.")
                    .foregroundStyle(.secondary)
            }
            Button { game.start() } label: {
                Label(game.state == .idle ? "Play" : "Play Again", systemImage: "play.fill")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(settings.accentColor)
            .padding(.top, 6)
        }
        .font(.subheadline)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 250)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private var confetti: some View {
        GeometryReader { proxy in
            Canvas { context, _ in
                context.translateBy(x: 0, y: Self.confettiRoom.height)
                game.drawConfetti(in: context, accent: settings.accentColor)
            }
            .frame(width: proxy.size.width + Self.confettiRoom.width, height: proxy.size.height + Self.confettiRoom.height)
            .offset(y: -Self.confettiRoom.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The bone on the reward and the bone counter: a bar with two knobs at each end.
private struct BoneShape: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = rect.width / 24
        var path = Path()
        path.move(to: CGPoint(x: 6.5 * unit, y: 6.5 * unit))
        path.addLine(to: CGPoint(x: 17.5 * unit, y: 17.5 * unit))
        path = path.strokedPath(StrokeStyle(lineWidth: 4.4 * unit, lineCap: .butt))
        for (x, y) in [(4.8, 7.6), (7.6, 4.8), (16.4, 19.2), (19.2, 16.4)] {
            path.addEllipse(in: CGRect(x: (x - 2.6) * unit, y: (y - 2.6) * unit, width: 5.2 * unit, height: 5.2 * unit))
        }
        return path.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// The game's state. Not observed: the card's timeline redraws every frame and reads it directly.
final class SignalCatchGame {
    enum Phase { case idle, play, win, lose }

    private struct Item { var x, y, speed, wobble: Double; var isCloud: Bool; var bars: Int; var isDone = false }
    private struct Pop { var x, y, life: Double; var text: String; var isBad = false; var isBig = false }
    private struct Piece { var x, y, vx, vy, spin, angle, width, height, life: Double; var color: Int }
    private struct Smear { var points: [CGPoint]; var born: Double }

    /// Seconds per run, and points for a full signal meter.
    static let round = 30.0
    static let goal = 100
    /// Every 5 catches in a row add ×1, up to ×3.
    private static let streakStep = 5
    private static let maxMultiplier = 3
    /// How long each ending plays before the result card.
    private static let winTime = 3.0
    private static let loseTime = 2.2
    /// The title pup is 64 × 40; the game pup is a little bigger.
    private static let pupScale = 1.15
    private static let pupWidth = 64 * pupScale
    /// Seconds into the win, when each lick starts, and how long it lasts.
    private static let licks = [0.6, 1.3]
    private static let lickTime = 0.55
    private static let bestKey = "signalCatch.best"
    private static let bonesKey = "signalCatch.bones"

    private(set) var state = Phase.idle
    private(set) var score = 0
    private(set) var timeLeft = round
    private(set) var showsResult = false
    private(set) var best = UserDefaults.standard.integer(forKey: bestKey)
    private(set) var bones = UserDefaults.standard.integer(forKey: bonesKey)
    var size = CGSize.zero
    private var width: Double { size.width }
    private var height: Double { size.height }
    /// The meter's right end, in the card's coordinates: where the confetti pops out.
    var confettiOrigin = CGPoint.zero

    private var pupX = 0.0, targetX = 0.0
    private var items: [Item] = [], pops: [Pop] = [], confetti: [Piece] = [], smears: [Smear?] = []
    private var streak = 0, ending = 0.0, stun = 0.0, spawnIn = 0.0
    private var reached = false
    private var last: Date?

    var multiplier: Int { min(Self.maxMultiplier, 1 + streak / Self.streakStep) }

    func start() {
        state = .play
        score = 0; timeLeft = Self.round; streak = 0; stun = 0; spawnIn = 0
        items = []; pops = []; smears = []; confetti = []
        reached = false; showsResult = false
    }

    /// The pup follows the finger, a little behind it.
    func aim(at x: Double) {
        targetX = min(max(x, Self.pupWidth / 2), width - Self.pupWidth / 2)
    }

    /// Moves the game to `date` and returns the time the drawing animates with.
    func advance(to date: Date) -> Double {
        let dt = last.map { min(0.05, max(0, date.timeIntervalSince($0))) } ?? 0
        last = date
        if width > 0 {
            if pupX == 0 { pupX = width / 2; targetX = pupX }
            update(dt)
        }
        return date.timeIntervalSinceReferenceDate
    }

    private func update(_ dt: Double) {
        pupX += (targetX - pupX) * min(1, dt * (stun > 0 ? 4 : 14))
        switch state {
        case .play:
            timeLeft -= dt
            stun = max(0, stun - dt)
            spawnIn -= dt
            if spawnIn <= 0 { spawn() }
            let catchY = height - 6 - 40 * Self.pupScale + 8
            for index in items.indices {
                items[index].y += items[index].speed * dt
                let item = items[index]
                guard !item.isDone, item.y > catchY, item.y < height - 10, abs(item.x - pupX) < Self.pupWidth / 2 + 6 else { continue }
                items[index].isDone = true
                if item.isCloud {
                    stun = 0.7; timeLeft -= 2; streak = 0
                    pops.append(Pop(x: item.x, y: catchY, life: 1, text: "−2s", isBad: true))
                } else {
                    let points = item.bars * multiplier
                    score += points; streak += 1
                    pops.append(Pop(x: item.x, y: catchY, life: 1, text: "+\(points)"))
                    if !reached, score >= Self.goal {
                        reached = true
                        burst()
                        pops.append(Pop(x: width / 2, y: height * 0.4, life: 1.6, text: "Full signal!", isBig: true))
                    }
                }
            }
            items.removeAll { $0.isDone || $0.y > height + 30 }
            if timeLeft <= 0 { timeLeft = 0; end() }
        case .win, .lose:
            ending += dt
            if !showsResult, ending > (state == .win ? Self.winTime : Self.loseTime) { showsResult = true }
        case .idle:
            break
        }
        for index in confetti.indices {
            confetti[index].vy += 520 * dt
            confetti[index].vx *= 1 - dt * 0.8
            confetti[index].x += confetti[index].vx * dt
            confetti[index].y += confetti[index].vy * dt
            confetti[index].angle += confetti[index].spin * dt
            confetti[index].life -= dt
        }
        confetti.removeAll { $0.life <= 0 || $0.y > height + 200 }
        for index in pops.indices {
            pops[index].life -= dt * (pops[index].isBig ? 0.7 : 1.4)
            pops[index].y -= dt * 40
        }
        pops.removeAll { $0.life <= 0 }
    }

    /// A full meter wins a bone and a big lick; anything less, the pup sobs.
    private func end() {
        state = score >= Self.goal ? .win : .lose
        ending = 0
        items = []
        if score > best {
            best = score
            UserDefaults.standard.set(best, forKey: Self.bestKey)
        }
        if state == .win {
            bones += 1
            UserDefaults.standard.set(bones, forKey: Self.bonesKey)
        }
    }

    /// The longer the run, the faster things fall and the more clouds there are.
    private func spawn() {
        let progress = 1 - timeLeft / Self.round
        items.append(Item(
            x: 20 + Double.random(in: 0...1) * (width - 40), y: -20,
            speed: 120 + progress * 140 + Double.random(in: 0...40), wobble: Double.random(in: 0...6),
            isCloud: Double.random(in: 0...1) < 0.18 + progress * 0.2, bars: Int.random(in: 1...3)
        ))
        spawnIn = 0.45 - progress * 0.2
    }

    /// Confetti out of the meter's right end, fanning from up-left to right; most pieces go up and right.
    private func burst() {
        for index in 0..<120 {
            let angle = -Double.pi * (0.02 + pow(Double.random(in: 0...1), 1.4) * 0.8)
            let speed = Double.random(in: 200...500)
            confetti.append(Piece(
                x: confettiOrigin.x, y: confettiOrigin.y, vx: cos(angle) * speed, vy: sin(angle) * speed,
                spin: .random(in: -6...6), angle: .random(in: 0...6), width: .random(in: 4...8), height: .random(in: 7...12),
                life: .random(in: 2.2...3.2), color: index % Self.confettiColors.count
            ))
        }
    }

    // MARK: Drawing

    private static let ink = Color(hex: 0x1c1c1e)
    private static let fur = Color(hex: 0xf2f2f7)
    private static let coat = Color(hex: 0xe5e5ea)
    private static let shade = Color(hex: 0xd1d1d6)
    private static let grey = Color(hex: 0x98989f)
    /// nil is the accent.
    private static let confettiColors: [Color?] = [nil, Color(hex: 0xffd60a), Color(hex: 0x30d158), Color(hex: 0xff9f0a), Color(hex: 0xf2f2f7), Color(hex: 0xbf5af2)]

    // The title pup's own shapes (SleepingPup in Offline.swift), so both pups are the same dog.
    private static let back: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 16, y: 36))
        path.addCurve(to: CGPoint(x: 40, y: 14), control1: CGPoint(x: 16, y: 22), control2: CGPoint(x: 27, y: 14))
        path.addCurve(to: CGPoint(x: 60, y: 31), control1: CGPoint(x: 52, y: 14), control2: CGPoint(x: 60, y: 22))
        path.addCurve(to: CGPoint(x: 55, y: 36), control1: CGPoint(x: 60, y: 34), control2: CGPoint(x: 58, y: 36))
        path.closeSubpath()
        return path
    }()
    private static let tail: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 59, y: 29))
        path.addCurve(to: CGPoint(x: 53, y: 36), control1: CGPoint(x: 62, y: 33), control2: CGPoint(x: 59, y: 37))
        return path
    }()
    private static let ear: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 22, y: 15))
        path.addCurve(to: CGPoint(x: 31, y: 27), control1: CGPoint(x: 30, y: 12), control2: CGPoint(x: 34, y: 19))
        path.addCurve(to: CGPoint(x: 24, y: 27), control1: CGPoint(x: 29.5, y: 30.5), control2: CGPoint(x: 25, y: 30.5))
        path.closeSubpath()
        return path
    }()
    private static let sleepEye: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 14, y: 23.5))
        path.addQuadCurve(to: CGPoint(x: 18.6, y: 23.5), control: CGPoint(x: 16.3, y: 25.5))
        return path
    }()

    func draw(in context: GraphicsContext, time: Double, accent: Color) {
        context.fill(Path(CGRect(x: 0, y: height - 6, width: width, height: 6)), with: .color(Color(hex: 0x2c2c2e)))
        for item in items {
            if item.isCloud {
                drawCloud(in: context, x: item.x, y: item.y)
            } else {
                drawWifi(in: context, x: item.x, y: item.y, bars: item.bars, tilt: sin(time * 4 + item.wobble) * 0.12, accent: accent)
            }
        }
        switch state {
        case .win: drawWin(in: context, time: time, accent: accent)
        case .lose: drawLose(in: context, time: time, accent: accent)
        case .play: drawPup(in: context, x: pupX, ground: height - 6, time: time, mood: .awake, accent: accent)
        case .idle: drawPup(in: context, x: pupX, ground: height - 6, time: time, mood: .sleep, accent: accent)
        }
        for pop in pops {
            var popContext = context
            popContext.opacity = min(1, pop.life)
            let color = pop.isBad ? Self.grey : pop.isBig ? .white : accent
            popContext.draw(
                Text(pop.text).font(.system(size: pop.isBig ? 30 : 16, weight: .heavy)).foregroundStyle(color),
                at: CGPoint(x: pop.x, y: pop.y), anchor: .bottom
            )
        }
    }

    func drawConfetti(in context: GraphicsContext, accent: Color) {
        for piece in confetti {
            var pieceContext = context
            pieceContext.opacity = min(1, piece.life)
            pieceContext.translateBy(x: piece.x, y: piece.y)
            pieceContext.rotate(by: .radians(piece.angle))
            pieceContext.scaleBy(x: 1, y: cos(piece.angle * 1.7))
            let rect = CGRect(x: -piece.width / 2, y: -piece.height / 2, width: piece.width, height: piece.height)
            pieceContext.fill(Path(rect), with: .color(Self.confettiColors[piece.color] ?? accent))
        }
    }

    /// A Wi-Fi symbol: a dot and up to three arcs, lit by how many points it's worth.
    private func drawWifi(in base: GraphicsContext, x: Double, y: Double, bars: Int, tilt: Double, accent: Color) {
        var context = base
        context.translateBy(x: x, y: y)
        context.rotate(by: .radians(tilt))
        for bar in 1...3 {
            var arc = Path()
            arc.addArc(center: CGPoint(x: 0, y: 8), radius: Double(bar) * 6.5, startAngle: .radians(.pi * 1.25), endAngle: .radians(.pi * 1.75), clockwise: false)
            context.stroke(arc, with: .color(bar <= bars ? accent : Self.grey.opacity(0.3)), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
        }
        context.fill(circle(0, 8, 2.6), with: .color(accent))
    }

    /// A grey cloud with a slash: no signal.
    private func drawCloud(in base: GraphicsContext, x: Double, y: Double) {
        var context = base
        context.translateBy(x: x, y: y)
        var cloud = circle(-9, 2, 8)
        cloud.addPath(circle(0, -3, 10))
        cloud.addPath(circle(10, 2, 8))
        cloud.addRect(CGRect(x: -17, y: 2, width: 35, height: 8))
        context.fill(cloud, with: .color(Color(hex: 0x48484a)))
        context.stroke(line(-8, 9, 8, -7), with: .color(Self.grey), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
    }

    private enum Mood { case sleep, awake, sad }

    /// The title pup, side on, snout to the left. sleep: the title's pose; awake: head up, eye open, trotting;
    /// sad: head down on the paws, brow up. x is its middle, ground its feet.
    private func drawPup(in base: GraphicsContext, x: Double, ground: Double, time: Double, mood: Mood, scale: Double = SignalCatchGame.pupScale, accent: Color) {
        let isMoving = mood == .awake && abs(targetX - pupX) > 2
        let facing: Double = mood == .awake && targetX > pupX + 1 ? -1 : 1   // flipped when running right
        let trot = isMoving ? abs(sin(time * 14)) * 2.5 : 0
        let breath = mood == .sleep ? sin(time * .pi * 2 / SleepingPup.zCycle) * 0.03 : 0
        // A sob: three quick hiccups, then a pause.
        let sobPhase = time.truncatingRemainder(dividingBy: 1.6) / 1.6
        let sob = mood == .sad && sobPhase < 0.45 ? abs(sin(sobPhase / 0.45 * .pi * 3)) * 0.06 : 0
        var context = base
        context.translateBy(x: x, y: ground - trot)
        context.scaleBy(x: scale * facing, y: scale)
        context.translateBy(x: -32, y: -38)

        // Body, hind leg and tail, breathing or sobbing from the ground up
        var body = context
        body.translateBy(x: 0, y: 36)
        body.scaleBy(x: 1, y: 1 + breath + sob)
        body.translateBy(x: 0, y: -36)
        body.fill(Self.back, with: .color(Self.coat))
        body.fill(circle(49, 30, 6.5), with: .color(Self.shade))
        var tail = body
        tail.translateBy(x: 56, y: 31)
        tail.rotate(by: .radians(mood == .awake ? sin(time * 18) * 0.5 : mood == .sad ? 0.5 : 0))
        tail.translateBy(x: -56, y: -31)
        tail.stroke(Self.tail, with: .color(Self.coat), style: StrokeStyle(lineWidth: 4, lineCap: .round))

        // Paws, stepping while it runs
        if mood == .awake {
            let stride = isMoving ? sin(time * 14) * 3 : 0
            context.fill(ellipse(20 + stride, 37, 4.5, 2.6), with: .color(Self.shade))
            context.fill(ellipse(44 - stride, 37, 4.5, 2.6), with: .color(Self.shade))
        }

        // Head: lifted when awake, resting on the paws otherwise
        var head = context
        head.translateBy(x: 0, y: mood == .awake ? -7 : mood == .sad ? 1 + sob * 20 : 0)
        head.fill(circle(21, 25, 10), with: .color(Self.fur))
        head.fill(ellipse(11, 29.5, 7.5, 5), with: .color(Self.fur))
        head.fill(circle(4.6, 28, 2.1), with: .color(Self.ink))
        let eyeStyle = StrokeStyle(lineWidth: 1.7, lineCap: .round)
        switch mood {
        case .awake where stun > 0:
            var cross = line(14, 21, 18, 25)
            cross.addPath(line(18, 21, 14, 25))
            head.stroke(cross, with: .color(Self.ink), style: eyeStyle)
        case .awake:
            head.fill(circle(16.3, 23, 2), with: .color(Self.ink))
            head.fill(circle(16.9, 22.4, 0.7), with: .color(.white))
        case .sad:
            // Eye squeezed shut, brow tipped up in the middle
            var eye = Path()
            eye.move(to: CGPoint(x: 14, y: 24.5))
            eye.addQuadCurve(to: CGPoint(x: 18.6, y: 24.5), control: CGPoint(x: 16.3, y: 22.5))
            head.stroke(eye, with: .color(Self.ink), style: eyeStyle)
            head.stroke(line(13.5, 19, 18.5, 20.5), with: .color(Self.ink), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        case .sleep:
            head.stroke(Self.sleepEye, with: .color(Self.ink), style: eyeStyle)
        }
        // The accent ear: bounces while running, droops when sad
        var ear = head
        ear.translateBy(x: 23, y: 16)
        ear.rotate(by: .radians(mood == .awake ? sin(time * 14) * (isMoving ? 0.18 : 0.05) - 0.1 : mood == .sad ? 0.35 : 0))
        ear.translateBy(x: -23, y: -16)
        ear.fill(Self.ear, with: .color(accent))

        // Front paw under the chin, as in the title
        if mood != .awake { context.fill(ellipse(17, 36, 7, 2.6), with: .color(Self.shade)) }
        // Dizzy stars after a cloud
        if mood == .awake, stun > 0 {
            for index in 0..<3 {
                let angle = time * 6 + Double(index) * 2.1
                context.draw(
                    Text("✦").font(.system(size: 9, weight: .bold)).foregroundStyle(Self.grey),
                    at: CGPoint(x: 21 + cos(angle) * 11, y: 8 + sin(angle) * 3)
                )
            }
        }
    }

    /// Lost: the pup lies down in the middle and sobs, tears dripping into a growing puddle.
    private func drawLose(in context: GraphicsContext, time: Double, accent: Color) {
        let scale = 1.7, x = width / 2, ground = height - 6
        let settle = ease(ending / 0.5)
        let pupAt = lerp(pupX, x, settle)
        let puddle = min(1, ending / 2)
        context.fill(
            ellipse(pupAt - 30 * scale, ground, 8 + 26 * puddle, 3 + 2 * puddle),
            with: .color(Color(red: 120 / 255, green: 170 / 255, blue: 1, opacity: 0.18 * puddle))
        )
        drawPup(in: context, x: pupAt, ground: ground, time: time, mood: settle < 1 ? .awake : .sad, scale: lerp(Self.pupScale, scale, settle), accent: accent)
        guard settle >= 1 else { return }
        // Tears, falling from the eye at their own pace
        let eyeX = pupAt + (16.3 - 32) * scale, eyeY = ground + (24 - 38) * scale
        for index in 0..<3 {
            let t = (time + Double(index) * 0.45).truncatingRemainder(dividingBy: 1.35) / 1.35
            let tearX = eyeX - 4 - t * 10, tearY = eyeY + t * t * 40
            var tear = Path()
            tear.move(to: CGPoint(x: tearX, y: tearY - 6))
            tear.addQuadCurve(to: CGPoint(x: tearX, y: tearY + 3), control: CGPoint(x: tearX + 4, y: tearY))
            tear.addQuadCurve(to: CGPoint(x: tearX, y: tearY - 6), control: CGPoint(x: tearX - 4, y: tearY))
            var tearContext = context
            tearContext.opacity = 1 - t * 0.6
            tearContext.fill(tear, with: .color(Color(hex: 0x8fc1ff)))
        }
    }

    /// Won: the pup rushes up to the screen, its face filling the card, panting with its tongue out of a closed :3 mouth.
    /// Each lick flips the tongue up to the nose and back, leaving a shiny streak on the glass.
    private func drawWin(in context: GraphicsContext, time: Double, accent: Color) {
        let t = ending
        let fullRadius = min(width * 0.5, height * 0.5 * 1.25)
        let homeY = height * 0.66
        var centre = CGPoint(x: width / 2, y: homeY), r = fullRadius
        if t < 0.45 {                                   // rushes up from where the pup stood
            let k = ease(t / 0.45)
            centre = CGPoint(x: lerp(pupX, width / 2, k), y: lerp(height - 24, homeY, k))
            r = lerp(20, fullRadius, k)
        } else if t > 2.25 {                            // backs away, small again
            let k = ease((t - 2.25) / (Self.winTime - 2.25))
            centre.y = lerp(homeY, height - 24, k)
            r = lerp(fullRadius, 20, k)
        }
        if t >= Self.winTime {
            drawPup(in: context, x: width / 2, ground: height - 6, time: time, mood: .awake, accent: accent)
            drawSmears(in: context, time: time)
            return
        }

        // flip: 0 hanging, 1 flipped up with the tip at the nose
        var flip = 0.0, lick = -1
        for (index, start) in Self.licks.enumerated() {
            let k = (t - start) / Self.lickTime
            if k >= 0, k <= 1 { flip = sin(k * .pi); lick = index }
        }
        let tip = CGPoint(x: centre.x, y: centre.y + r * 0.27 + r * lerp(0.24, -0.08, flip))
        if lick >= 0, flip > 0.2 {
            while smears.count <= lick { smears.append(nil) }
            if smears[lick] == nil { smears[lick] = Smear(points: [], born: time) }
            smears[lick]?.points.append(tip)
            smears[lick]?.born = time
        }

        var face = context
        face.translateBy(x: centre.x, y: centre.y)
        face.scaleBy(x: 1 + flip * 0.05, y: 1 + flip * 0.05)   // each lick pushes the face into the glass a little
        for side in [-1.0, 1.0] {
            // Starts and ends inside the head, so the ear grows out of it.
            var ear = Path()
            ear.move(to: CGPoint(x: side * r * 0.3, y: -r * 0.7))
            ear.addCurve(to: CGPoint(x: side * r * 1.08, y: -r * 0.05), control1: CGPoint(x: side * r * 0.75, y: -r), control2: CGPoint(x: side * r * 1.12, y: -r * 0.62))
            ear.addCurve(to: CGPoint(x: side * r * 0.78, y: r * 0.48), control1: CGPoint(x: side * r * 1.06, y: r * 0.38), control2: CGPoint(x: side * r * 0.92, y: r * 0.58))
            ear.addCurve(to: CGPoint(x: side * r * 0.6, y: -r * 0.2), control1: CGPoint(x: side * r * 0.66, y: r * 0.4), control2: CGPoint(x: side * r * 0.62, y: r * 0.1))
            ear.closeSubpath()
            face.fill(ear, with: .color(accent))
        }
        face.fill(circle(0, 0, r * 0.86), with: .color(Self.fur))
        face.fill(ellipse(0, r * 0.28, r * 0.44, r * 0.3), with: .color(.white))
        for side in [-1.0, 1.0] {
            // Eyebrow spots in the accent
            var brow = face
            brow.translateBy(x: side * r * 0.27, y: -r * 0.36)
            brow.rotate(by: .radians(side * -0.35))
            brow.opacity = 0.55
            brow.fill(ellipse(0, 0, r * 0.07, r * 0.045), with: .color(accent))
            // Whisker dots on the snout
            for (x, y) in [(0.25, 0.17), (0.32, 0.21), (0.26, 0.25)] {
                face.fill(circle(side * r * x, r * y, r * 0.018), with: .color(Color(hex: 0x3c3c43, opacity: 0.35)))
            }
            // Eyes: squeezed shut mid-lick
            if flip > 0.1 {
                var eye = Path()
                eye.move(to: CGPoint(x: side * r * 0.44, y: -r * 0.12))
                eye.addQuadCurve(to: CGPoint(x: side * r * 0.22, y: -r * 0.12), control: CGPoint(x: side * r * 0.33, y: -r * 0.24))
                face.stroke(eye, with: .color(Self.ink), style: StrokeStyle(lineWidth: r * 0.045, lineCap: .round))
            } else {
                face.fill(circle(side * r * 0.33, -r * 0.14, r * 0.08), with: .color(Self.ink))
                face.fill(circle(side * r * 0.31, -r * 0.17, r * 0.025), with: .color(.white))
            }
            // Full red cheeks with /// on them
            let cheek = CGPoint(x: side * r * 0.54, y: r * 0.12)
            face.fill(ellipse(cheek.x, cheek.y, r * 0.13, r * 0.085), with: .color(Color(hex: 0xff5470, opacity: 0.55)))
            var hatch = Path()
            for dx in [-0.055, 0, 0.055] {
                hatch.addPath(line(cheek.x + r * (dx - 0.02), cheek.y + r * 0.04, cheek.x + r * (dx + 0.02), cheek.y - r * 0.04))
            }
            face.stroke(hatch, with: .color(Color(hex: 0xd63052, opacity: 0.85)), style: StrokeStyle(lineWidth: r * 0.02, lineCap: .round))
        }
        let nose = ellipse(0, r * 0.12, r * 0.13, r * 0.09)
        face.fill(nose, with: .color(Self.ink))
        drawMouthAndTongue(in: face, r: r, flip: flip, time: time, nose: nose)
        drawSmears(in: context, time: time)
    }

    /// A closed :3 mouth in the face's coordinates, the tongue hanging from under it, or flipped up over it to the nose.
    private func drawMouthAndTongue(in face: GraphicsContext, r: Double, flip: Double, time: Double, nose: Path) {
        let mouthY = r * 0.27, width = r * 0.2, lobe = r * 0.085
        let crease = StrokeStyle(lineWidth: max(1.5, r * 0.022), lineCap: .round)
        // Hanging, panting a little; it pulls in as it flips up.
        let drop = r * (0.24 + sin(time * 11) * 0.03) * (1 - flip)
        let tipY = mouthY + max(drop, width / 2)

        // Only the part below the two curves of the :3 shows, so its root sits behind the mouth.
        var hanging = face
        var below = Path()
        below.move(to: CGPoint(x: -lobe * 2, y: mouthY))
        below.addArc(center: CGPoint(x: -lobe, y: mouthY), radius: lobe, startAngle: .radians(.pi), endAngle: .zero, clockwise: true)
        below.addArc(center: CGPoint(x: lobe, y: mouthY), radius: lobe, startAngle: .radians(.pi), endAngle: .zero, clockwise: true)
        below.addLine(to: CGPoint(x: lobe * 2, y: mouthY + r))
        below.addLine(to: CGPoint(x: -lobe * 2, y: mouthY + r))
        below.closeSubpath()
        hanging.clip(to: below)
        let tongue = UnevenRoundedRectangle(
            topLeadingRadius: width * 0.15, bottomLeadingRadius: width / 2, bottomTrailingRadius: width / 2, topTrailingRadius: width * 0.15
        ).path(in: CGRect(x: -width / 2, y: mouthY - width * 0.2, width: width, height: tipY - mouthY + width * 0.2))
        hanging.fill(tongue, with: .linearGradient(
            Gradient(stops: [.init(color: Color(hex: 0xc8445c), location: 0), .init(color: Color(hex: 0xff7a90), location: 0.35), .init(color: Color(hex: 0xff8fa2), location: 1)]),
            startPoint: CGPoint(x: 0, y: mouthY), endPoint: CGPoint(x: 0, y: tipY)
        ))
        hanging.stroke(line(0, mouthY + lobe * 0.6, 0, lerp(mouthY, tipY, 0.7)), with: .color(Color(hex: 0xc8465f, opacity: 0.55)), style: crease)

        // The :3: a short line down from the nose, then a curve to each side.
        var mouth = line(0, r * 0.2, 0, mouthY)
        mouth.addArc(center: CGPoint(x: -lobe, y: mouthY), radius: lobe, startAngle: .zero, endAngle: .radians(.pi * 0.95), clockwise: false)
        mouth.move(to: CGPoint(x: 0, y: mouthY))
        mouth.addArc(center: CGPoint(x: lobe, y: mouthY), radius: lobe, startAngle: .radians(.pi), endAngle: .radians(.pi * 0.05), clockwise: true)
        face.stroke(mouth, with: .color(Self.ink), style: StrokeStyle(lineWidth: r * 0.04, lineCap: .round))

        guard flip > 0.03 else { return }
        // Flipped: in front of the :3, rising to the nose and widening until it hides both curves, darker underside showing.
        let flippedWidth = lerp(width, lobe * 4 + r * 0.07, flip)
        let top = lerp(mouthY, r * 0.19, flip), bottom = mouthY + lerp(width * 0.35, lobe + r * 0.04, flip)
        let height = bottom - top
        face.fill(
            Path(roundedRect: CGRect(x: -flippedWidth / 2, y: top, width: flippedWidth, height: height), cornerRadius: min(flippedWidth, height) / 2),
            with: .linearGradient(Gradient(colors: [Color(hex: 0xd9445f), Color(hex: 0xff7a90)]), startPoint: CGPoint(x: 0, y: bottom), endPoint: CGPoint(x: 0, y: top))
        )
        face.stroke(line(0, bottom - width * 0.2, 0, lerp(bottom, top, 0.7)), with: .color(Color(hex: 0xaa2846, opacity: 0.5)), style: crease)
        // The nose again, on top, so the tip tucks under it
        face.fill(nose, with: .color(Self.ink))
    }

    /// The streak each lick leaves on the glass: a faint wet band along the tongue tip's path, with a shine line.
    private func drawSmears(in context: GraphicsContext, time: Double) {
        for smear in smears.compactMap({ $0 }) where smear.points.count > 1 {
            let fade = max(0, 1 - (time - smear.born) / 1.8)
            guard fade > 0 else { continue }
            var band = Path()
            band.addLines(smear.points)
            context.stroke(band, with: .color(Color(red: 220 / 255, green: 235 / 255, blue: 1, opacity: 0.14 * fade)), style: StrokeStyle(lineWidth: 26, lineCap: .round, lineJoin: .round))
            context.stroke(band.offsetBy(dx: -6, dy: -5), with: .color(.white.opacity(0.55 * fade)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
private func ease(_ t: Double) -> Double { 1 - pow(1 - min(1, max(0, t)), 3) }
private func circle(_ x: Double, _ y: Double, _ radius: Double) -> Path { ellipse(x, y, radius, radius) }
private func ellipse(_ x: Double, _ y: Double, _ rx: Double, _ ry: Double) -> Path {
    Path(ellipseIn: CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2))
}
private func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: x1, y: y1))
    path.addLine(to: CGPoint(x: x2, y: y2))
    return path
}

private extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255, blue: Double(hex & 0xff) / 255, opacity: opacity)
    }
}
