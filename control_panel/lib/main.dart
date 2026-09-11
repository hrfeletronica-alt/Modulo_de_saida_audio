import 'package:flutter/material.dart';

void main() {
  runApp(const AudioMixerApp());
}

class AudioMixerApp extends StatelessWidget {
  const AudioMixerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Audio Mixer Control Panel',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF1E1E1E),
      ),
      home: const MixerScreen(),
    );
  }
}

class MixerScreen extends StatefulWidget {
  const MixerScreen({super.key});

  @override
  State<MixerScreen> createState() => _MixerScreenState();
}

class _MixerScreenState extends State<MixerScreen> {
  // 1 Input (index 0) + 10 Outputs (index 1 to 10) = 11 channels
  final int totalChannels = 11;
  late List<double> _volumes;
  late List<bool> _mutes;

  @override
  void initState() {
    super.initState();
    _volumes = List.filled(totalChannels, 0.7);
    _mutes = List.filled(totalChannels, false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Painel de Controle de Áudio'),
        backgroundColor: Colors.black87,
      ),
      body: Container(
        color: const Color(0xFF2B2B2B),
        padding: const EdgeInsets.all(8.0),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: List.generate(totalChannels, (index) {
              final isInput = index == 0;
              final channelNumber = isInput ? 'LR' : '$index';
              final defaultName = isInput ? 'Entrada' : 'Ch $index';
              
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2.0),
                child: ChannelStrip(
                  channelIndex: index,
                  channelNumber: channelNumber,
                  defaultName: defaultName,
                  isInput: isInput,
                  volume: _volumes[index],
                  isMuted: _mutes[index],
                  onVolumeChanged: (value) {
                    setState(() {
                      _volumes[index] = value;
                    });
                  },
                  onMuteToggled: () {
                    setState(() {
                      _mutes[index] = !_mutes[index];
                    });
                  },
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class ChannelStrip extends StatefulWidget {
  final int channelIndex;
  final String channelNumber;
  final String defaultName;
  final bool isInput;
  final double volume;
  final bool isMuted;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onMuteToggled;

  const ChannelStrip({
    super.key,
    required this.channelIndex,
    required this.channelNumber,
    required this.defaultName,
    this.isInput = false,
    required this.volume,
    required this.isMuted,
    required this.onVolumeChanged,
    required this.onMuteToggled,
  });

  @override
  State<ChannelStrip> createState() => _ChannelStripState();
}

class _ChannelStripState extends State<ChannelStrip> {
  late TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.defaultName);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _showEQDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2B2B2B),
          title: Text(
            'EQ Paramétrico - ${_nameController.text}',
            style: const TextStyle(color: Colors.white),
          ),
          content: SizedBox(
            width: 700,
            height: 350,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildParametricBand('Band 1 (Low)', 60, 20, 250),
                _buildParametricBand('Band 2 (L-Mid)', 400, 200, 1000),
                _buildParametricBand('Band 3 (Mid)', 2000, 800, 4000),
                _buildParametricBand('Band 4 (H-Mid)', 6000, 3000, 10000),
                _buildParametricBand('Band 5 (High)', 12000, 8000, 20000),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Concluído', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildParametricBand(String label, double defaultFreq, double minFreq, double maxFreq) {
    return Container(
      width: 120,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        border: Border.all(color: const Color(0xFF444444)),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          // Gain Slider (Vertical)
          Expanded(
            child: RotatedBox(
              quarterTurns: -1,
              child: SliderTheme(
                data: const SliderThemeData(trackHeight: 2),
                child: Slider(
                  value: 0,
                  min: -15,
                  max: 15,
                  onChanged: (val) {}, // Mock logic
                ),
              ),
            ),
          ),
          const Text('0 dB', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          // Frequency
          const Text('Freq (Hz)', style: TextStyle(color: Colors.grey, fontSize: 10)),
          SizedBox(
            height: 20,
            child: Slider(
              value: defaultFreq,
              min: minFreq,
              max: maxFreq,
              activeColor: const Color(0xFFFF5500),
              onChanged: (val) {}, // Mock
            ),
          ),
          Text('${defaultFreq.toInt()} Hz', style: const TextStyle(color: Colors.grey, fontSize: 10)),
          const SizedBox(height: 5),
          // Q Factor
          const Text('Q (Largura)', style: TextStyle(color: Colors.grey, fontSize: 10)),
          SizedBox(
            height: 20,
            child: Slider(
              value: 1.0,
              min: 0.1,
              max: 10.0,
              activeColor: const Color(0xFFFF5500),
              onChanged: (val) {}, // Mock
            ),
          ),
          const Text('1.0', style: TextStyle(color: Colors.grey, fontSize: 10)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 80,
      decoration: BoxDecoration(
        color: const Color(0xFFB0B0B0),
        border: Border.all(color: Colors.black, width: 2),
      ),
      child: Column(
        children: [
          // Parametric EQ Display (Clickable)
          GestureDetector(
            onTap: () => _showEQDialog(context),
            child: EQDisplay(seed: widget.channelIndex + 1),
          ),
          
          // Mute Button
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 4.0),
            child: GestureDetector(
              onTap: widget.onMuteToggled,
              child: Container(
                height: 30,
                decoration: BoxDecoration(
                  color: widget.isMuted ? Colors.red : const Color(0xFFDEDEDE),
                  border: Border.all(color: Colors.black, width: 2),
                  borderRadius: BorderRadius.circular(4),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Mute',
                  style: TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ),
          
          // Fader Area
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 2.0),
              decoration: BoxDecoration(
                color: Colors.black,
                border: Border.all(
                  color: widget.isInput ? const Color(0xFFFF5500) : Colors.black, 
                  width: widget.isInput ? 2 : 1
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Meter Background
                  Positioned(
                    left: 8,
                    top: 10,
                    bottom: 10,
                    width: 12,
                    child: Container(
                      color: const Color(0xFF1A3300),
                    ),
                  ),
                  // Meter Level (Simulated)
                  Positioned(
                    left: 8,
                    bottom: 10,
                    width: 12,
                    height: 200 * widget.volume, // Simulate meter height based on volume
                    child: Container(
                      color: widget.isMuted ? Colors.transparent : const Color(0xFF4C9900),
                    ),
                  ),
                  
                  // Fader Track
                  Positioned(
                    right: 25,
                    top: 20,
                    bottom: 20,
                    width: 4,
                    child: Container(
                      color: const Color(0xFF111111),
                    ),
                  ),
                  
                  // Scale Markings
                  Positioned(
                    right: 4,
                    top: 20,
                    bottom: 20,
                    width: 20,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: const [
                        Text('10', style: TextStyle(color: Colors.white, fontSize: 8)),
                        Text('5', style: TextStyle(color: Colors.white, fontSize: 8)),
                        Text('U', style: TextStyle(color: Colors.white, fontSize: 8)),
                        Text('-5', style: TextStyle(color: Colors.white, fontSize: 8)),
                        Text('-10', style: TextStyle(color: Colors.white, fontSize: 8)),
                        Text('-20', style: TextStyle(color: Colors.white, fontSize: 8)),
                        Text('-30', style: TextStyle(color: Colors.white, fontSize: 8)),
                        Text('-40', style: TextStyle(color: Colors.white, fontSize: 8)),
                        Text('-50', style: TextStyle(color: Colors.white, fontSize: 8)),
                        Text('∞', style: TextStyle(color: Colors.white, fontSize: 8)),
                      ],
                    ),
                  ),
                  
                  // The Slider
                  RotatedBox(
                    quarterTurns: -1,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 0,
                        activeTrackColor: Colors.transparent,
                        inactiveTrackColor: Colors.transparent,
                        thumbShape: const FaderThumbShape(),
                        overlayShape: SliderComponentShape.noOverlay,
                      ),
                      child: Slider(
                        value: widget.volume,
                        onChanged: widget.onVolumeChanged,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          // Editable Channel Label Area
          Container(
            height: 50,
            width: double.infinity,
            color: widget.isInput ? const Color(0xFF552200) : const Color(0xFF999999),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  widget.channelNumber,
                  style: TextStyle(
                    color: widget.isInput ? Colors.white : Colors.black,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4.0),
                  child: Container(
                    height: 20,
                    color: widget.isInput ? Colors.transparent : Colors.white.withOpacity(0.8),
                    child: widget.isInput
                      ? Center(
                          child: Text(
                            widget.defaultName,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        )
                      : TextField(
                          controller: _nameController,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.black,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.only(bottom: 12),
                          ),
                        ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Visual Mock EQ Display widget
class EQDisplay extends StatelessWidget {
  final int seed;
  const EQDisplay({super.key, required this.seed});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      margin: const EdgeInsets.only(top: 4, left: 4, right: 4, bottom: 0),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2200),
        border: Border.all(color: Colors.black, width: 2),
        borderRadius: BorderRadius.circular(4),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: CustomPaint(
          painter: EQPainter(seed),
          child: Container(), // Empty container to take up space
        ),
      ),
    );
  }
}

class EQPainter extends CustomPainter {
  final int seed;
  EQPainter(this.seed);

  @override
  void paint(Canvas canvas, Size size) {
    // deterministic random generator based on channel index so curves stay still
    double random(int offset) {
      return ((seed * 37 + offset * 13) % 100) / 100.0;
    }

    final w = size.width;
    final h = size.height;
    
    final offset1 = random(1) * w * 0.3 + w * 0.1;
    final offset2 = random(2) * w * 0.3 + w * 0.5;
    final dip1 = (random(3) * 0.6 + 0.2) * h;
    final dip2 = (random(4) * 0.6 + 0.2) * h;

    final path = Path()
      ..moveTo(0, h/2)
      ..cubicTo(offset1 - 10, h/2, offset1, dip1, offset1 + 10, dip1)
      ..cubicTo(offset2 - 20, dip1, offset2 - 10, dip2, offset2, dip2)
      ..cubicTo(offset2 + 10, dip2, w - 10, h/2, w, h/2);

    final fillPath = Path.from(path)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();

    final fillPaint = Paint()
      ..color = Colors.white.withOpacity(0.3)
      ..style = PaintingStyle.fill;
    
    final strokePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, strokePaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}


// Custom Thumb Shape to look like a mixing console fader knob
class FaderThumbShape extends SliderComponentShape {
  const FaderThumbShape();

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    return const Size(40, 20);
  }

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final Canvas canvas = context.canvas;
    
    final Rect thumbRect = Rect.fromCenter(
      center: center,
      width: 24.0, 
      height: 40.0, 
    );

    final Paint paint = Paint()..color = const Color(0xFFE0E0E0);
    final Paint borderPaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    final Paint linePaint = Paint()
      ..color = Colors.black54
      ..strokeWidth = 2.0;

    canvas.drawRRect(
      RRect.fromRectAndRadius(thumbRect, const Radius.circular(4.0)),
      paint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(thumbRect, const Radius.circular(4.0)),
      borderPaint,
    );

    canvas.drawLine(
      Offset(center.dx - 4, center.dy - 12),
      Offset(center.dx - 4, center.dy + 12),
      linePaint,
    );
    canvas.drawLine(
      Offset(center.dx + 4, center.dy - 12),
      Offset(center.dx + 4, center.dy + 12),
      linePaint,
    );
  }
}
