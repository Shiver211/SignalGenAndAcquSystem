"""读取一次交织 RAW、包络和测量，拟合外部正弦并记录奇偶点失配。"""
from __future__ import annotations
import argparse
import json
import socket
import sys
from time import monotonic
from pathlib import Path
import numpy as np
from scipy.optimize import minimize_scalar
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from host.tests.live_m8_integration import ControlClient, receive_frames
from host.comm.control_protocol import Command, DataMode, acquisition_payload, processing_payload
from host.comm.data_protocol import SampleFormat, decode_raw32, decode_measurement_v1
from host.config import PC_IP, UDP_PORT

def save_waveform(samples, sample_rate, frequency, path):
    # 本地可选绘图依赖放在 build/plotting；正常安装 matplotlib 时优先用环境依赖。
    sys.path.append(str(Path(__file__).resolve().parents[1]/"build"/"plotting"))
    from matplotlib.figure import Figure
    from matplotlib.backends.backend_agg import FigureCanvasAgg
    fig=Figure(figsize=(11,4),dpi=140,layout="constrained")
    FigureCanvasAgg(fig)
    ax=fig.subplots()
    count=min(len(samples),int(sample_rate/frequency*4))
    t=np.arange(count)/sample_rate*1e6
    v=samples[:count].astype(float)*(10.0/4095.0)-5.0
    ax.plot(t,v,color="#aaaaaa",linewidth=0.7)
    for parity,color,label in ((0,"#0072b2","Even"),(1,"#d55e00","Odd")):
        ax.plot(t[parity::2],v[parity::2],"o",color=color,markersize=2.8,label=label)
    ax.set(title=f"INA interleave | {sample_rate/1e6:g} MSps | {frequency/1e6:g} MHz",
           xlabel="Time (us)",ylabel="Voltage (V)")
    ax.grid(alpha=0.2)
    ax.legend(loc="upper right")
    fig.savefig(path)

def fit_sine(samples, sample_rate, expected_frequency):
    volts = samples.astype(float) * (10.0 / 4095.0) - 5.0
    t = np.arange(len(volts)) / sample_rate
    def fit(frequency, parity=None):
        ts = t if parity is None else t[parity::2]
        ys = volts if parity is None else volts[parity::2]
        phase = 2*np.pi*frequency*ts
        matrix = np.column_stack((np.sin(phase), np.cos(phase), np.ones(len(ts))))
        coeff = np.linalg.lstsq(matrix, ys, rcond=None)[0]
        residual = ys - matrix @ coeff
        return coeff, float(np.mean(residual**2))
    spectrum = np.abs(np.fft.rfft((volts-volts.mean()) * np.hanning(len(volts))))
    bins = np.fft.rfftfreq(len(volts), 1/sample_rate)
    window = (bins > expected_frequency*0.95) & (bins < expected_frequency*1.05)
    peak = bins[np.flatnonzero(window)[np.argmax(spectrum[window])]]
    width = sample_rate/len(volts)
    frequency = minimize_scalar(lambda f: fit(f)[1], bounds=(peak-width, peak+width), method="bounded").x
    coeff, residual = fit(frequency)
    even, even_residual = fit(frequency,0)
    odd, odd_residual = fit(frequency,1)
    amp = lambda c: float(np.hypot(c[0],c[1]))
    phase_delta = np.angle(np.exp(1j*(np.arctan2(odd[1],odd[0])-np.arctan2(even[1],even[0]))))
    return {"frequency_hz":float(frequency),"vpp":2*amp(coeff),"offset_v":float(coeff[2]),
            "residual_rms_v":float(np.sqrt(residual)),
            "odd_even_offset_mv":float((odd[2]-even[2])*1000),
            "odd_even_gain_error_percent":float((amp(odd)/amp(even)-1)*100),
            "odd_even_time_skew_ps":float(phase_delta/(2*np.pi*frequency)*1e12),
            "even_residual_rms_v":float(np.sqrt(even_residual)),
            "odd_residual_rms_v":float(np.sqrt(odd_residual))}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port",default="COM4")
    parser.add_argument("--frequency",type=float,required=True)
    parser.add_argument("--vpp",type=float,default=3.0)
    parser.add_argument("--output",type=Path,required=True)
    args=parser.parse_args()
    args.output.parent.mkdir(parents=True,exist_ok=True)
    control=ControlClient(args.port)
    sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,4*1024*1024)
    sock.settimeout(0.05)
    sock.bind((PC_IP,UDP_PORT))
    result={"expected_frequency_hz":args.frequency,"expected_vpp":args.vpp}
    try:
        control.ok(Command.STOP)
        control.ok(Command.ENVELOPE_ENABLE,b"\x00")
        control.ok(Command.SET_ACQUISITION,acquisition_payload(
            0,2048,16,0,65539,0,channel_mask=1,sampling_mode=1))
        control.ok(Command.SET_PROCESSING,processing_payload(DataMode.RAW,1,1024,20))
        result["configured"]=control.status()
        control.ok(Command.ARM)
        raw=receive_frames(sock,control,{SampleFormat.RAW16},8)[SampleFormat.RAW16]
        result["raw_header"]=vars(raw.header)
        if raw.header.sample_rate_hz!=130_000_000 or not raw.header.flags&0x100 or raw.header.total_samples!=65539:
            raise RuntimeError(f"RAW 描述符不符合交织配置：{raw.header}")
        decoded=decode_raw32(raw.payload,raw.header.channel_mask)
        samples=decoded["a"]
        np.savez(args.output.with_suffix(".npz"),code=samples,otr=decoded["otr_a"],sample_rate_hz=raw.header.sample_rate_hz)
        result["raw"]=fit_sine(samples,raw.header.sample_rate_hz,args.frequency)
        save_waveform(samples,raw.header.sample_rate_hz,args.frequency,args.output.with_suffix(".png"))
        result["raw"]["samples"]=len(samples)
        result["raw"]["otr_count"]=int(decoded["otr_a"].sum())
        result["raw"]["minmax_vpp"]=(int(samples.max())-int(samples.min()))*10.0/4095.0
        result["raw"]["amplitude_error_percent"]=(result["raw"]["vpp"]/args.vpp-1)*100
        result["raw"]["frequency_error_percent"]=(result["raw"]["frequency_hz"]/args.frequency-1)*100
        control.ok(Command.SET_ACQUISITION,acquisition_payload(
            0,2048,16,0,13000,0,channel_mask=1,sampling_mode=1,commit=False))
        control.ok(Command.SET_PROCESSING,processing_payload(DataMode.ENVELOPE,1,1000,20))
        control.ok(Command.ENVELOPE_ENABLE,b"\x01")
        frames=receive_frames(sock,control,{SampleFormat.ENVELOPE32,SampleFormat.MEASUREMENT_V1},8)
        for frame in frames.values():
            if frame.header.channel_mask!=1 or not frame.header.flags&0x100:
                raise RuntimeError("包络或测量未标记交织模式")
        env=frames[SampleFormat.ENVELOPE32]
        result["envelope"]={"points":env.header.total_samples,"sample_rate_hz":env.header.sample_rate_hz}
        measurement=decode_measurement_v1(frames[SampleFormat.MEASUREMENT_V1].payload)
        # 首窗口用于学习施密特阈值，等待下一窗口的有效频率。
        deadline=monotonic()+3
        while not measurement.period_valid_a and monotonic()<deadline:
            frame=receive_frames(sock,control,{SampleFormat.MEASUREMENT_V1},1)[SampleFormat.MEASUREMENT_V1]
            measurement=decode_measurement_v1(frame.payload)
        result["measurement"]=vars(measurement)
        result["measurement"]["frequency_error_percent"]=(measurement.frequency_hz_a/args.frequency-1)*100
        result["measurement"]["vpp_v"]=measurement.vpp_a*10.0/4095.0
        result["measurement"]["amplitude_error_percent"]=(result["measurement"]["vpp_v"]/args.vpp-1)*100
        result["status"]=control.status()
        result["sine_fit_passed"]=bool(abs(result["raw"]["amplitude_error_percent"])<=3 and
                              abs(result["raw"]["frequency_error_percent"])<=1 and
                              measurement.period_valid_a and
                              abs(result["measurement"]["frequency_error_percent"])<=1 and
                              not result["status"]["sample_overflow"] and
                              result["raw"]["otr_count"]==0)
        result["minmax_amplitude_passed"]=abs(result["measurement"]["amplitude_error_percent"])<=3
        result["passed"]=result["sine_fit_passed"] and result["minmax_amplitude_passed"]
    finally:
        try:
            control.ok(Command.ENVELOPE_ENABLE,b"\x00")
            control.ok(Command.STOP)
            result["final_status"]=control.status()
        finally:
            sock.close();control.close()
            args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding="utf-8")
    print(json.dumps(result,ensure_ascii=False,indent=2))
    return 0 if result["passed"] else 1
if __name__=="__main__":
    raise SystemExit(main())
