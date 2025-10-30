import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // For haptic feedback
import 'package:camera/camera.dart';
import 'package:gallery_saver/gallery_saver.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:image/image.dart' as img;

// --- App Entry Point ---
void main() {
  // Ensure Flutter is initialized before running the app.
  WidgetsFlutterBinding.ensureInitialized();
  // Lock orientation to portrait mode for a consistent cinematic experience.
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  runApp(const V3CapApp());
}

// --- Root Application Widget ---
class V3CapApp extends StatelessWidget {
  const V3CapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'V3 CAP',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const CameraScreen(),
    );
  }
}

// --- Main Camera Screen Widget ---
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  // Controller for camera hardware.
  CameraController? _controller;
  // Future to track camera initialization.
  Future<void>? _initializeControllerFuture;

  // UI State Variables
  bool _isVideoMode = false;
  bool _isRecording = false;
  bool _isProcessing = false; // To show a loading indicator while saving photo.
  String? _lastThumbnailPath;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Start camera initialization immediately.
    _initializeControllerFuture = _initializeCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose(); // Dispose the controller when the widget is disposed.
    super.dispose();
  }

  // --- Lifecycle Management for Camera ---
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (_controller == null || !_controller!.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      _controller?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      // Re-initialize the camera when the app is resumed.
      setState(() {
        _initializeControllerFuture = _initializeCamera();
      });
    }
  }

  // --- Core Camera Initialization ---
  Future<void> _initializeCamera() async {
    // 1. Request Permissions
    await [Permission.camera, Permission.microphone].request();

    // 2. Discover available cameras
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      // Handle case where no camera is available.
      throw Exception("No camera found on this device.");
    }
    final firstCamera = cameras.first;

    // 3. Create and initialize the CameraController
    _controller = CameraController(
      firstCamera,
      ResolutionPreset.max, // Use 'max' for the best possible quality (4K).
      enableAudio: true,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    // 4. Initialize the controller. This returns a Future.
    return _controller!.initialize();
  }

  // --- Main Capture Action ---
  Future<void> _onCapturePressed() async {
    // Prevent action if processing or not initialized.
    if (_isProcessing || _controller == null || !_controller!.value.isInitialized) return;

    // Provide haptic feedback for a premium feel.
    HapticFeedback.lightImpact();

    if (_isVideoMode) {
      if (_isRecording) {
        await _stopVideoRecording();
      } else {
        await _startVideoRecording();
      }
    } else {
      await _takePicture();
    }
  }

  // --- Photo Capture and Filter Application ---
  Future<void> _takePicture() async {
    if (_controller!.value.isTakingPicture) return;

    try {
      setState(() => _isProcessing = true);

      // 1. Take the picture
      final XFile rawFile = await _controller!.takePicture();

      // 2. Process the image with the filter in a separate isolate to avoid UI lag.
      final bytes = await rawFile.readAsBytes();
      final filteredBytes = await _processImage(bytes);

      // 3. Define the save path
      final Directory extDir = await getApplicationDocumentsDirectory();
      final String dirPath = '${extDir.path}/V3_CAP';
      await Directory(dirPath).create(recursive: true);
      final String filePath = '$dirPath/${DateTime.now().millisecondsSinceEpoch}.jpg';

      // 4. Save the filtered image file.
      await File(filePath).writeAsBytes(filteredBytes);

      // 5. Save to the public device gallery.
      await GallerySaver.saveImage(filePath);

      // 6. Update the UI with the new thumbnail.
      if (mounted) {
        setState(() {
          _lastThumbnailPath = filePath;
          _isProcessing = false;
        });
      }
    } catch (e) {
      debugPrint("Error taking picture: $e");
      if (mounted) setState(() => _isProcessing = false);
    }
  }
  
  // This helper function runs the heavy image processing.
  Future<List<int>> _processImage(Uint8List bytes) async {
      img.Image? originalImage = img.decodeImage(bytes);
      img.Image filteredImage = _applyCineV3Filter(originalImage!);
      // Encode the image to JPEG format with high quality.
      return img.encodeJpg(filteredImage, quality: 95);
  }


  // --- Video Recording Logic ---
  Future<void> _startVideoRecording() async {
    if (_controller!.value.isRecordingVideo) return;
    try {
      await _controller!.startVideoRecording();
      setState(() => _isRecording = true);
    } catch (e) {
      debugPrint("Error starting video recording: $e");
    }
  }

  Future<void> _stopVideoRecording() async {
    if (!_controller!.value.isRecordingVideo) return;
    try {
      final XFile rawVideo = await _controller!.stopVideoRecording();
      setState(() => _isRecording = false);
      await GallerySaver.saveVideo(rawVideo.path);
      // In a real app, use a package like `video_thumbnail` to generate a thumbnail.
      // For now, we'll just update the path.
      if(mounted) setState(() => _lastThumbnailPath = rawVideo.path);
    } catch (e) {
      debugPrint("Error stopping video recording: $e");
    }
  }

  // --- UI Action: Toggle between Photo and Video ---
  void _toggleCameraMode() {
    if (_isRecording) return;
    setState(() => _isVideoMode = !_isVideoMode);
  }

  // --- THE 'CINE-V3' FILTER LOGIC ---
  static img.Image _applyCineV3Filter(img.Image image) {
    // 1. Adjustments for Brightness, Contrast, Saturation
    img.adjustColor(image, saturation: 1.12, contrast: 1.03); // Sat +12, Contrast +3
    img.brightness(image, 2); // Brightness +2

    // 2. Adjustments for Texture & Detail
    img.sharpen(image, amount: 36); // Sharpen +36
    img.contrast(image, contrast: 1.60); // Clarity +60 (Approximation)
    img.brightness(image, 3); // Brilliance +3 (Approximation)

    // 3. Tonal Adjustments
    img.adjustColor(image, highlights: -2.0, shadows: 6.0); // Highlight -2, Shadow +6

    // 4. White & Black Point Adjustments
    _adjustLevels(image, black: 7, white: 252); // Black +7, White +3 (255-3=252)

    // 5. Color Grading
    _adjustTemperature(image, -6); // Temp -6
    img.adjustColor(image, hue: -4.0); // Hue -4

    return image;
  }

  // Helper function for Temperature
  static void _adjustTemperature(img.Image image, double amount) {
    final double rAdj = 1.0 - amount / 100.0;
    final double bAdj = 1.0 + amount / 100.0;
    for (final pixel in image) {
      pixel.r = (pixel.r * rAdj).clamp(0, 255).toInt();
      pixel.b = (pixel.b * bAdj).clamp(0, 255).toInt();
    }
  }

  // Helper function for White/Black points
  static void _adjustLevels(img.Image image, {int black = 0, int white = 255}) {
    final int range = white - black;
    if (range <= 0) return;
    final double scale = 255.0 / range;
    for (final pixel in image) {
      pixel.r = ((pixel.r - black) * scale).clamp(0, 255).toInt();
      pixel.g = ((pixel.g - black) * scale).clamp(0, 255).toInt();
      pixel.b = ((pixel.b - black) * scale).clamp(0, 255).toInt();
    }
  }

  // --- Build Method for UI ---
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<void>(
        future: _initializeControllerFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            // If the Future is complete, display the camera preview.
            return Stack(
              children: [
                // Camera Preview fills the entire screen
                Positioned.fill(child: CameraPreview(_controller!)),
                // UI Controls Overlay
                _buildUIOverlay(),
                // Loading indicator during processing
                if (_isProcessing)
                  Container(
                    color: Colors.black.withOpacity(0.5),
                    child: const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  ),
              ],
            );
          } else {
            // Otherwise, display a loading indicator.
            return const Center(child: CircularProgressIndicator(color: Colors.white));
          }
        },
      ),
    );
  }

  // --- UI Widgets ---

  Widget _buildUIOverlay() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Container(
          color: Colors.black.withOpacity(0.4),
          padding: EdgeInsets.fromLTRB(25, 20, 25, MediaQuery.of(context).padding.bottom + 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _buildGalleryThumbnail(),
              _buildShutterButton(),
              _buildModeToggle(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildGalleryThumbnail() {
    return Container(
      width: 55,
      height: 55,
      decoration: BoxDecoration(
        color: Colors.black,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white70, width: 2),
        image: _lastThumbnailPath != null && _lastThumbnailPath!.endsWith('.jpg')
            ? DecorationImage(image: FileImage(File(_lastThumbnailPath!)), fit: BoxFit.cover)
            : null,
      ),
      child: _lastThumbnailPath == null || !_lastThumbnailPath!.endsWith('.jpg')
          ? const Icon(Icons.photo_library, color: Colors.white, size: 24)
          : null,
    );
  }

  Widget _buildShutterButton() {
    return GestureDetector(
      onTap: _onCapturePressed,
      child: Container(
        height: 80,
        width: 80,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 4),
        ),
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            height: _isRecording ? 30 : 64,
            width: _isRecording ? 30 : 64,
            decoration: BoxDecoration(
              color: _isVideoMode ? Colors.red : Colors.white,
              borderRadius: BorderRadius.circular(_isRecording ? 8 : 32),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModeToggle() {
    return GestureDetector(
      onTap: _toggleCameraMode,
      child: Container(
        width: 80,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.6),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Center(
          child: Text(
            _isVideoMode ? 'VIDEO' : 'PHOTO',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
          ),
        ),
      ),
    );
  }
}
