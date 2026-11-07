"""OdaiCam の効果音と BGM をつくる（すべて自前の合成。外部の素材は使わない）

使い方: python OdaiCam/Tools/make_audio.py
出力先: OdaiCam/Resources/Audio/*.wav（48 kHz・モノラル・16 bit。山は -3 dBFS にそろえる）
numpy が要る（python -m pip install --user numpy）。乱数の種を固定しているので、何度作っても同じ音になる。
"""
import math
import os
import wave

import numpy as np

SR = 48000
PEAK = 10 ** (-3 / 20)  # -3 dBFS
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "Audio")
rng = np.random.default_rng(20261106)


# ---------- 道具 ----------

def t_axis(seconds):
    return np.arange(int(round(seconds * SR))) / SR


def midi(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def fade(x, fin=0.004, fout=0.006):
    """頭と終わりを短くなだらかにして、プチッという音を消す"""
    x = x.copy()
    a, b = int(fin * SR), int(fout * SR)
    if a > 0:
        x[:a] *= np.sin(np.linspace(0, math.pi / 2, a)) ** 2
    if b > 0:
        x[-b:] *= np.cos(np.linspace(0, math.pi / 2, b)) ** 2
    return x


def normalize(x, peak=PEAK):
    x = x - np.mean(x)
    m = np.max(np.abs(x))
    return x if m == 0 else x * (peak / m)


def biquad(x, kind, fc, q=0.707):
    """RBJ の 2 次フィルタ（短い音にだけ使う）"""
    w = 2 * math.pi * fc / SR
    alpha = math.sin(w) / (2 * q)
    cw = math.cos(w)
    if kind == "lp":
        b = [(1 - cw) / 2, 1 - cw, (1 - cw) / 2]
    elif kind == "hp":
        b = [(1 + cw) / 2, -(1 + cw), (1 + cw) / 2]
    else:  # bp（山の高さ 0 dB）
        b = [alpha, 0, -alpha]
    a = [1 + alpha, -2 * cw, 1 - alpha]
    b = [v / a[0] for v in b]
    a1, a2 = a[1] / a[0], a[2] / a[0]
    y = np.zeros_like(x)
    x1 = x2 = y1 = y2 = 0.0
    for i, v in enumerate(x):
        o = b[0] * v + b[1] * x1 + b[2] * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, v, y1, o
        y[i] = o
    return y


def sweep_bandpass(x, f_start, f_end, q=2.0, curve=1.0):
    """中心の高さを動かす帯域フィルタ（Chamberlin の SVF）。シュッという音の本体"""
    n = len(x)
    y = np.zeros_like(x)
    low = band = 0.0
    damp = 1.0 / q
    for i in range(n):
        p = (i / max(n - 1, 1)) ** curve
        fc = f_start * (f_end / f_start) ** p
        f = 2 * math.sin(math.pi * min(fc, SR / 6) / SR)
        high = x[i] - low - damp * band
        band += f * high
        low += f * band
        y[i] = band
    return y


def additive(f, t, harmonics, decay_base, decay_per_k, detune=0.0, phase_seed=None):
    """倍音を足して作る音（帯域を守るので折り返しのにごりが出ない）。高い倍音ほど早く消える"""
    out = np.zeros_like(t)
    rs = np.random.default_rng(phase_seed)
    for k, amp in harmonics:
        fk = f * k
        if fk >= SR / 2 * 0.9:
            break
        ph = rs.uniform(0, 2 * math.pi) if phase_seed is not None else 0.0
        out += amp * np.sin(2 * math.pi * fk * (1 + detune) * t + ph) * np.exp(-t * (decay_base + decay_per_k * k))
    return out


def saw_partials(n):
    return [(k, 1.0 / k) for k in range(1, n + 1)]


def square_partials(n):
    return [(k, 1.0 / k) for k in range(1, n + 1, 2)]


def adsr(n, a=0.005, d=0.08, s=0.6, r=0.03):
    env = np.ones(n) * s
    na, nd, nr = int(a * SR), int(d * SR), int(r * SR)
    na = min(na, n)
    env[:na] = np.linspace(0, 1, na)
    nd = min(nd, n - na)
    env[na:na + nd] = np.linspace(1, s, nd)
    if nr > 0 and nr < n:
        env[-nr:] *= np.linspace(1, 0, nr)
    return env


def write(name, x, peak=PEAK):
    x = normalize(x, peak)
    pcm = np.clip(np.round(x * 32767), -32768, 32767).astype("<i2")
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print(f"{name}: {len(x) / SR:.2f} s, peak {20 * math.log10(np.max(np.abs(x))):.1f} dBFS, {os.path.getsize(path) // 1024} KB")


# ---------- 打楽器 ----------

def kick():
    t = t_axis(0.42)
    f = 48 + 120 * np.exp(-t / 0.035)
    body = np.sin(2 * math.pi * np.cumsum(f) / SR) * np.exp(-t / 0.22)
    # スマホのスピーカーでも聞こえるよう、倍音と頭のカチッを足す
    knock = np.tanh(2.5 * body) * 0.5
    click = biquad(rng.standard_normal(len(t)), "hp", 2500) * np.exp(-t / 0.004) * 0.6
    return fade(body + knock + click, 0.0005, 0.02)


def clap():
    t = t_axis(0.3)
    noise = biquad(rng.standard_normal(len(t)), "bp", 1400, 0.9)
    env = np.zeros_like(t)
    for d in (0.0, 0.011, 0.022):
        env += np.where(t >= d, np.exp(-(t - d) / 0.007), 0)
    env += np.where(t >= 0.03, 0.55 * np.exp(-(t - 0.03) / 0.09), 0)
    tone = np.sin(2 * math.pi * 210 * t) * np.exp(-t / 0.04) * 0.3
    return fade(noise * env * 1.6 + tone, 0.0005, 0.02)


def hat(open_=False):
    t = t_axis(0.25 if open_ else 0.07)
    noise = biquad(biquad(rng.standard_normal(len(t)), "hp", 7000), "hp", 7000)
    return fade(noise * np.exp(-t / (0.07 if open_ else 0.015)), 0.0005, 0.01)


def crash():
    t = t_axis(1.6)
    noise = biquad(rng.standard_normal(len(t)), "hp", 4500)
    return fade(noise * np.exp(-t / 0.5), 0.001, 0.05)


# ---------- 音程のある音 ----------

def pluck(f, seconds, bright=1.0):
    t = t_axis(seconds)
    voices = sum(additive(f, t, saw_partials(24), 3.0, 0.9 / bright, detune=d, phase_seed=i)
                 for i, d in enumerate((-0.005, 0.0, 0.005)))
    return fade(voices * adsr(len(t), 0.003, 0.05, 0.9, 0.04), 0.002, 0.02)


def bass(f, seconds):
    t = t_axis(seconds)
    raw = np.sin(2 * math.pi * f * t) + 0.45 * np.sin(2 * math.pi * 2 * f * t) + 0.2 * np.sin(2 * math.pi * 3 * f * t)
    return fade(np.tanh(1.6 * raw) * adsr(len(t), 0.004, 0.12, 0.7, 0.03), 0.002, 0.015)


def lead(f, seconds):
    t = t_axis(seconds)
    vib = 1 + 0.004 * np.sin(2 * math.pi * 5.5 * t) * np.clip(t / 0.15, 0, 1)
    sq = sum(a * np.sin(2 * math.pi * f * k * np.cumsum(vib) / SR) for k, a in square_partials(9))
    tri = np.sin(2 * math.pi * f * np.cumsum(vib) / SR)
    return fade((0.35 * sq + 0.8 * tri) * adsr(len(t), 0.01, 0.1, 0.7, 0.05), 0.003, 0.03)


# ---------- BGM ----------

def bgm():
    """115 BPM・8 小節の繰り返し。F - C - Dm - B♭ の明るい進行。最後と最初がつながるように作る"""
    bpm = 115
    step = 60 / bpm / 4  # 16 分音符
    bars = 8
    length = int(round(bars * 16 * step * SR))
    drums = np.zeros(length + SR * 2)
    music = np.zeros(length + SR * 2)

    def put(x, at_step, gain=1.0, to=None):
        buf = music if to is None else to
        i = int(round(at_step * step * SR))
        buf[i:i + len(x)] += x * gain

    k, c, hc, ho, cr = kick(), clap(), hat(), hat(True), crash()
    # コードは 1 小節ずつ（根音・構成音）
    chords = [(53, [65, 69, 72]), (48, [64, 67, 72]), (50, [65, 69, 74]), (46, [65, 70, 74])] * 2
    # 後半 4 小節だけのメロディ（小節, 16 分の位置, 音, 長さ）
    melody = [
        (4, 0, 77, 3), (4, 4, 76, 2), (4, 6, 77, 2), (4, 8, 81, 4), (4, 14, 79, 2),
        (5, 0, 79, 3), (5, 4, 76, 2), (5, 6, 74, 2), (5, 8, 72, 6),
        (6, 0, 74, 3), (6, 4, 77, 2), (6, 6, 81, 2), (6, 8, 84, 4), (6, 12, 81, 4),
        (7, 0, 82, 3), (7, 4, 81, 2), (7, 6, 79, 2), (7, 8, 77, 4), (7, 12, 72, 2), (7, 14, 74, 2),
    ]
    duck = np.ones(length + SR * 2)
    for bar in range(bars):
        b0 = bar * 16
        root, notes = chords[bar]
        for s in (0, 4, 8, 12):
            put(k, b0 + s, 0.95, drums)
            i = int(round((b0 + s) * step * SR))
            n = int(0.18 * SR)
            duck[i:i + n] = np.minimum(duck[i:i + n], 1 - 0.55 * np.exp(-np.arange(n) / SR / 0.06))
        for s in (4, 12):
            put(c, b0 + s, 0.6, drums)
        for s in range(16):
            if s % 4 == 2:
                put(ho if s == 14 and bar % 2 == 1 else hc, b0 + s, 0.32, drums)
            elif s % 2 == 1:
                put(hc, b0 + s, 0.12, drums)
        # 最後の小節は手拍子を足して頭に戻す
        if bar == bars - 1:
            for s in (13, 14, 15):
                put(c, b0 + s, 0.35, drums)
        # ベースは 8 分で根音とオクターブを交互に
        for s in range(0, 16, 2):
            f = midi(root - 12 + (12 if s % 4 == 2 else 0))
            put(bass(f, step * 1.8), b0 + s, 0.55)
        # コードは裏拍に短く刻む
        for s in (2, 6, 10, 14, 15) if bar % 2 else (2, 6, 10, 14):
            for m in notes:
                put(pluck(midi(m), step * 1.6, bright=1.2), b0 + s, 0.13)
        # 前半は分散和音、後半はメロディ
        if bar < 4:
            arp = [notes[0] + 12, notes[1] + 12, notes[2] + 12, notes[1] + 12]
            for j, s in enumerate((0, 3, 6, 8, 11, 14)):
                put(pluck(midi(arp[j % 4]), step * 1.5, bright=0.8), b0 + s, 0.09)
    for bar, s, m, ln in melody:
        put(lead(midi(m), step * ln * 0.95), bar * 16 + s, 0.2)
    put(cr, 0, 0.25, drums)

    # キックに合わせて伴奏だけ少し引っ込める（ポンプ感）
    mix = drums + music * duck
    # 端からはみ出た余韻を頭に重ね、切れ目なく回るようにする
    tail = len(mix) - length
    mix[:tail] += mix[length:]
    mix = mix[:length]
    mix = np.tanh(mix / np.max(np.abs(mix)) * 1.4)  # 軽く押しつぶして音圧を出す
    return mix


# ---------- 効果音 ----------

def tick():
    t = t_axis(0.09)
    x = np.sin(2 * math.pi * 1750 * t) * np.exp(-t / 0.018) + 0.5 * np.sin(2 * math.pi * 2840 * t) * np.exp(-t / 0.01)
    x += biquad(rng.standard_normal(len(t)), "hp", 3000) * np.exp(-t / 0.002) * 0.4
    return fade(x, 0.0005, 0.01)


def go():
    t = t_axis(0.38)
    x = additive(midi(88), t, [(1, 1.0), (2, 0.35), (3, 0.15)], 6.0, 1.5)
    x += 0.5 * additive(midi(95), t, [(1, 1.0), (2, 0.3)], 7.0, 2.0)
    return fade(x * adsr(len(t), 0.002, 0.05, 0.85, 0.08), 0.002, 0.03)


def bell(f, seconds):
    t = t_axis(seconds)
    partials = [(1, 1.0), (2.0, 0.55), (3.0, 0.22), (4.16, 0.12), (5.43, 0.06)]
    x = np.zeros_like(t)
    for k, a in partials:
        x += a * np.sin(2 * math.pi * f * k * t) * np.exp(-t * (3.2 + 2.2 * k))
    return x


def correct():
    """ピンポン（4 度で上がる明るい 2 音）"""
    gap = 0.095
    t = t_axis(0.75)
    x = np.zeros_like(t)
    a = bell(midi(83), 0.75 - 0.0)
    b = bell(midi(88), 0.75 - gap)
    x += a * 0.85
    x[int(gap * SR):] += b[:len(x) - int(gap * SR)]
    # 1 音目は 2 音目が鳴ったら少し引く
    x[int(gap * SR):] -= a[int(gap * SR):] * 0.45 * np.clip((t[int(gap * SR):] - gap) / 0.03, 0, 1)
    return fade(x, 0.001, 0.08)


def swish(seconds, f0, f1, q=1.8, shape=1.5):
    t = t_axis(seconds)
    noise = rng.standard_normal(len(t))
    x = sweep_bandpass(noise, f0, f1, q)
    env = np.sin(math.pi * np.clip(t / seconds, 0, 1)) ** shape
    return fade(x * env, 0.003, 0.02)


def pass_():
    x = swish(0.32, 4500, 700, q=1.6, shape=1.2)
    t = t_axis(0.32)
    # 低めの「ポン」で終わったことを分かりやすく
    pop = np.sin(2 * math.pi * (300 - 120 * t / 0.32) * t) * np.exp(-np.clip(t - 0.18, 0, None) / 0.05) * (t > 0.18)
    return fade(x + 0.25 * pop, 0.003, 0.03)


def buzzer():
    """ブブー（2 回）。低めの矩形波を 2 本ずらして濁らせる"""
    parts = []
    for seconds in (0.16, 0.36):
        t = t_axis(seconds)
        x = additive(131, t, square_partials(25), 0.0, 0.0) + additive(138, t, square_partials(25), 0.0, 0.0)
        x = np.tanh(0.8 * x)
        parts.append(fade(x * adsr(len(t), 0.004, 0.05, 0.85, 0.04), 0.003, 0.03))
        parts.append(np.zeros(int(0.06 * SR)))
    x = np.concatenate(parts[:-1])
    return biquad(x, "lp", 3200)


def finish():
    """短いファンファーレ（ド・ミ・ソ・ドで上がって伸ばす）"""
    unit = 0.11
    total = unit * 3 + 0.9
    t_all = t_axis(total)
    x = np.zeros_like(t_all)

    def brass(f, seconds):
        t = t_axis(seconds)
        vib = 1 + 0.005 * np.sin(2 * math.pi * 6 * t) * np.clip((t - 0.12) / 0.2, 0, 1)
        ph = 2 * math.pi * f * np.cumsum(vib) / SR
        # 吹き始めは倍音が少なく、すぐに明るくなる
        bright = np.clip(t / 0.04, 0.2, 1)
        y = sum((1 / k) * np.sin(k * ph) * bright ** (k * 0.4) for k in range(1, 14) if f * k < SR / 2.2)
        return fade(y * adsr(len(t), 0.012, 0.08, 0.75, 0.12), 0.003, 0.1)

    for i, m in enumerate((72, 76, 79)):
        n = brass(midi(m), unit * 0.95)
        s = int(i * unit * SR)
        x[s:s + len(n)] += n * 0.8
    s = int(3 * unit * SR)
    for m, g in ((84, 0.8), (79, 0.45), (76, 0.4), (72, 0.4)):
        n = brass(midi(m), 0.9)
        x[s:s + len(n)] += n[:len(x) - s] * g
    sh = crash()
    x[s:] += sh[:len(x) - s] * 0.12
    return fade(x, 0.002, 0.12)


def riser():
    """種明かしの前の「見えていた画面」で流す、上がっていく音。終わりが答えの場面の頭にそろう"""
    seconds = 1.6
    t = t_axis(seconds)
    p = t / seconds
    noise = sweep_bandpass(rng.standard_normal(len(t)), 350, 7000, q=3.0, curve=1.6)
    f = 180 * (4.0 ** (p ** 1.4))
    trem = 0.75 + 0.25 * np.sin(2 * math.pi * np.cumsum(6 + 22 * p) / SR)
    tone = (np.sin(2 * math.pi * np.cumsum(f) / SR) + 0.3 * np.sin(2 * math.pi * np.cumsum(2.01 * f) / SR)) * trem
    env = p ** 1.8
    return fade((noise * 1.2 + tone * 0.35) * env, 0.01, 0.012)


def hit():
    """種明かしの瞬間のドン"""
    t = t_axis(0.9)
    f = 42 + 90 * np.exp(-t / 0.05)
    boom = np.sin(2 * math.pi * np.cumsum(f) / SR) * np.exp(-t / 0.3)
    boom = np.tanh(2.2 * boom)
    snap = biquad(rng.standard_normal(len(t)), "bp", 1800, 0.7) * np.exp(-t / 0.03) * 0.7
    air = biquad(rng.standard_normal(len(t)), "hp", 5000) * np.exp(-t / 0.25) * 0.2
    return fade(boom + snap + air, 0.0008, 0.1)


def whoosh():
    return swish(0.5, 600, 5000, q=2.2, shape=2.0)


if __name__ == "__main__":
    write("bgm.wav", bgm())
    write("tick.wav", tick())
    write("go.wav", go())
    write("correct.wav", correct())
    write("pass.wav", pass_())
    write("buzzer.wav", buzzer())
    write("finish.wav", finish())
    write("riser.wav", riser())
    write("hit.wav", hit())
    write("whoosh.wav", whoosh())
