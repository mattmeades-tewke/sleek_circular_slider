library circular_slider;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sleek_circular_slider/src/slider_animations.dart';
import 'utils.dart';
import 'appearance.dart';
import 'slider_label.dart';
import 'dart:math' as math;

part 'curve_painter.dart';
part 'custom_gesture_recognizer.dart';

typedef void OnChange(double value);
typedef Widget InnerWidget(double percentage);

class SleekCircularSlider extends StatefulWidget {
  final double initialValue;
  final double min;
  final double max;
  final CircularSliderAppearance appearance;
  final OnChange onChange;
  final OnChange onChangeStart;
  final OnChange onChangeEnd;
  final InnerWidget innerWidget;

  // New variable, defines the 'hot area' that the user can grab on the slider
  // Can be set to zero if user interaction isn't required
  final double touchWidth;

  // Defines the duration of the secondary animation in milliseconds - if < 0 (default), then secondary
  // animation is disabled
  final int secondaryAnimDuration;

  // Define the list of colors to fade between, [0] is starting colour, [1] is end colour
  final List<Color> secondaryAnimColors;

  // Changed from static to var - need to modify the progress bar colour
  // COMMENTED OUT - User now needs to provide an appearance variable
  // static var defaultAppearance = CircularSliderAppearance();

  double get angle {
    return valueToAngle(initialValue, min, max, appearance.angleRange);
  }

  // No longer const
  SleekCircularSlider({
    Key key,
    this.initialValue = 50,
    this.min = 0,
    this.max = 100,
    @required this.appearance = null,
    this.onChange,
    this.onChangeStart,
    this.onChangeEnd,
    this.innerWidget,
    this.touchWidth = 25,
    this.secondaryAnimDuration = -1,
    this.secondaryAnimColors,
  })  : assert(initialValue != null),
        assert(min != null),
        assert(max != null),
        assert(min <= max),
        assert(initialValue >= min && initialValue <= max),
        assert(secondaryAnimColors == null || secondaryAnimColors.length == 2),
        super(key: key);
  @override
  _SleekCircularSliderState createState() => _SleekCircularSliderState();
}

class _SleekCircularSliderState extends State<SleekCircularSlider> with TickerProviderStateMixin {
  bool _isHandlerSelected;
  bool _animationInProgress = false;
  _CurvePainter _painter;
  double _oldWidgetAngle;
  double _oldWidgetValue;
  double _currentAngle;
  double _startAngle;
  double _angleRange;
  double _selectedAngle;
  double _rotation;
  SpinAnimationManager _spinManager;
  ValueChangedAnimationManager _animationManager;

  // Create animation manager (defined in 'slider_animations.dart')
  ColorChangedAnimationManager _colorChangedAnimationManager;

  // Takes the input from widget and stores the colours that the fade animation moves between
  List<Color> _secondaryAnimColors;

  // When fading out, need to keep track of initial angle so that the progress
  // bar can be held there while it fades out
  double _storedAngle;

  // Toggle this on/off to tell other functions it is currently fading out
  bool _fadingOut = false;

  // Set to false at start so that button doesn't run the animation when the screen loads
  bool _initialising = true;

  bool get _interactionEnabled =>
      (widget.onChangeEnd != null || widget.onChange != null && !widget.appearance.spinnerMode);

  @override
  void initState() {
    super.initState();
    _startAngle = widget.appearance.startAngle;
    _angleRange = widget.appearance.angleRange;

    if (!widget.appearance.animationEnabled) {
      return;
    }

    widget.appearance.spinnerMode ? _spin() : _animate();
  }

  @override
  void didUpdateWidget(SleekCircularSlider oldWidget) {
    if (oldWidget.angle != widget.angle) {
      _animate();
    }
    super.didUpdateWidget(oldWidget);
  }

  void _animate() {
    if (_initialising) {
      _initialising = false;
      return;
    }

    if (!widget.appearance.animationEnabled || widget.appearance.spinnerMode) {
      _setupPainter();
      _updateOnChange();
      return;
    }
    if (_animationManager == null) {
      _animationManager = ValueChangedAnimationManager(
        tickerProvider: this,
        minValue: widget.min,
        maxValue: widget.max,
        durationMultiplier: widget.appearance.animDurationMultiplier,
      );
    }

    // Instantiates the animation manager & sets the animation colours if not already set
    if (_colorChangedAnimationManager == null && widget.secondaryAnimDuration >= 0) {
      _colorChangedAnimationManager = ColorChangedAnimationManager(
        tickerProvider: this,
        duration: widget.secondaryAnimDuration,
      );
      if (widget.secondaryAnimColors == null) {
        // Colours default from progress bar back to track colour
        _secondaryAnimColors = [
          widget.appearance.customColors.progressBarColor,
          widget.appearance.trackColor,
        ];
      } else {
        _secondaryAnimColors = widget.secondaryAnimColors;
      }
    }

    // Save stored angle as the previous widget angle
    _storedAngle = _oldWidgetAngle;

    //// MAIN NEW MODIFICATION
    // Instead of animating the progress bar back to 0 when the button is turned off, this
    // fades out the line instead if:
    // --- new angle == 0 (button has been pressed to turn the lights off) AND
    // --- the stored angle != null (this is so that the animation isn't run on startup)
    // --- the animation duration >= 0 (otherwise the animation is disabled and the original
    //     code in the else block is run)
    if (widget.angle == 0 && _storedAngle != null && widget.secondaryAnimDuration >= 0) {
      _fadingOut = true;
      _colorChangedAnimationManager.animate(
          color1: _secondaryAnimColors[0],
          color2: _secondaryAnimColors[1],
          colorChangeAnimation: ((Color animColor, bool animationCompleted) {
            setState(() {
              if (!animationCompleted) {
                widget.appearance.customColors.progressBarColor = animColor;
                // Set current angle to stored angle so progress bar holds in place while fading out
                _currentAngle = _storedAngle;
                // update painter and the on change closure
                _setupPainter();
                _updateOnChange();
              } else {
                _fadingOut = false;
                _currentAngle = 0;
              }
            });
          }));
      // Standard animation
    } else {
      _animationManager.animate(
          initialValue: widget.initialValue,
          angle: widget.angle,
          oldAngle: _oldWidgetAngle,
          oldValue: _oldWidgetValue,
          valueChangedAnimation: ((double anim, bool animationCompleted) {
            _animationInProgress = !animationCompleted;
            setState(() {
              if (!animationCompleted) {
                _currentAngle = anim;
                // update painter and the on change closure
                _setupPainter();
                _updateOnChange();
              }
            });
          }));
    }
  }

  void _spin() {
    _spinManager = SpinAnimationManager(
        tickerProvider: this,
        duration: Duration(milliseconds: widget.appearance.spinnerDuration),
        spinAnimation: ((double anim1, anim2, anim3) {
          setState(() {
            _rotation = anim1 != null ? anim1 : 0;
            _startAngle = anim2 != null ? math.pi * anim2 : 0;
            _currentAngle = anim3 != null ? anim3 : 0;
            _setupPainter();
            _updateOnChange();
          });
        }));
    _spinManager.spin();
  }

  @override
  Widget build(BuildContext context) {
    /// If painter is null there is a need to setup it to prevent exceptions.
    if (_painter == null) {
      _setupPainter();
    }
    return RawGestureDetector(gestures: <Type, GestureRecognizerFactory>{
      _CustomPanGestureRecognizer: GestureRecognizerFactoryWithHandlers<_CustomPanGestureRecognizer>(
        () => _CustomPanGestureRecognizer(
          onPanDown: _onPanDown,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
        ),
        (_CustomPanGestureRecognizer instance) {},
      ),
    }, child: _buildRotatingPainter(rotation: _rotation, size: Size(widget.appearance.size, widget.appearance.size)));
  }

  @override
  void dispose() {
    if (_spinManager != null) _spinManager.dispose();
    if (_animationManager != null) _animationManager.dispose();
    super.dispose();
  }

  void _setupPainter({bool counterClockwise = false}) {
    var defaultAngle = _currentAngle ?? widget.angle;
    if (_oldWidgetAngle != null) {
      if (_oldWidgetAngle != widget.angle) {
        _selectedAngle = null;
        defaultAngle = widget.angle;
      }
    }

    // If using fade out animation, don't need function to calculate angle
    // --- Causes button to flash if not taken out because it jumps to 0, then
    //     back to previous value
    if (!_fadingOut) {
      _currentAngle = calculateAngle(
          startAngle: _startAngle,
          angleRange: _angleRange,
          selectedAngle: _selectedAngle,
          defaultAngle: defaultAngle,
          counterClockwise: counterClockwise);
    }

    _painter = _CurvePainter(
        startAngle: _startAngle,
        angleRange: _angleRange,
        angle: _currentAngle < 0.5 ? 0.5 : _currentAngle,
        appearance: widget.appearance);
    _oldWidgetAngle = widget.angle;
    _oldWidgetValue = widget.initialValue;
  }

  void _updateOnChange() {
    if (widget.onChange != null && !_animationInProgress) {
      final value = angleToValue(_currentAngle, widget.min, widget.max, _angleRange);
      widget.onChange(value);
    }
  }

  Widget _buildRotatingPainter({double rotation, Size size}) {
    if (rotation != null) {
      return Transform(
          transform: Matrix4.identity()..rotateZ((rotation) * 5 * math.pi / 6),
          alignment: FractionalOffset.center,
          child: _buildPainter(size: size));
    } else {
      return _buildPainter(size: size);
    }
  }

  Widget _buildPainter({Size size}) {
    return CustomPaint(
        painter: _painter, child: Container(width: size.width, height: size.height, child: _buildChildWidget()));
  }

  Widget _buildChildWidget() {
    if (widget.appearance.spinnerMode) {
      return null;
    }
    final value = angleToValue(_currentAngle, widget.min, widget.max, _angleRange);
    final childWidget = widget.innerWidget != null
        ? widget.innerWidget(value)
        : SliderLabel(
            value: value,
            appearance: widget.appearance,
          );
    return childWidget;
  }

  void _onPanUpdate(Offset details) {
    if (!_isHandlerSelected) {
      return;
    }
    if (_painter.center == null) {
      return;
    }
    _handlePan(details, false);
  }

  void _onPanEnd(Offset details) {
    _handlePan(details, true);
    if (widget.onChangeEnd != null) {
      widget.onChangeEnd(angleToValue(_currentAngle, widget.min, widget.max, _angleRange));
    }

    _isHandlerSelected = false;
  }

  void _handlePan(Offset details, bool isPanEnd) {
    if (_painter.center == null) {
      return;
    }
    RenderBox renderBox = context.findRenderObject();
    var position = renderBox.globalToLocal(details);
    final double touchWidth = widget.appearance.progressBarWidth >= 25.0 ? widget.appearance.progressBarWidth : 25.0;
    if (isPointAlongCircle(position, _painter.center, _painter.radius, touchWidth)) {
      _selectedAngle = coordinatesToRadians(_painter.center, position);
      // setup painter with new angle values and update onChange
      _setupPainter(counterClockwise: widget.appearance.counterClockwise);
      _updateOnChange();
      setState(() {});
    }
  }

  bool _onPanDown(Offset details) {
    if (_painter == null || _interactionEnabled == false) {
      return false;
    }
    RenderBox renderBox = context.findRenderObject();
    var position = renderBox.globalToLocal(details);

    if (position == null) {
      return false;
    }

    final angleWithinRange = isAngleWithinRange(
        startAngle: _startAngle,
        angleRange: _angleRange,
        touchAngle: coordinatesToRadians(_painter.center, position),
        previousAngle: _currentAngle,
        counterClockwise: widget.appearance.counterClockwise);
    if (!angleWithinRange) {
      return false;
    }

    // final double touchWidth = widget.appearance.progressBarWidth >= 25.0 ? widget.appearance.progressBarWidth : 25.0;
    final double touchWidth = widget.touchWidth;

    if (isPointAlongCircle(position, _painter.center, _painter.radius, touchWidth)) {
      _isHandlerSelected = true;
      if (widget.onChangeStart != null) {
        widget.onChangeStart(angleToValue(_currentAngle, widget.min, widget.max, _angleRange));
      }
      _onPanUpdate(details);
    } else {
      _isHandlerSelected = false;
    }

    return _isHandlerSelected;
  }
}
