/// Retry manager for handling retries with exponential backoff
library retry_manager;

import 'dart:async';
import '../utils/logger.dart';

class RetryManager {
  final int retries;
  final Function(Object error, int attempt, int retries)? onRetry;
  final Duration Function(int attempt)? sleepFunction;
  final bool fatal;
  
  int _attempt = 0;
  Object? _error;
  static const Object _noError = _NoError();
  
  RetryManager({
    this.retries = 3,
    this.onRetry,
    this.sleepFunction,
    this.fatal = true,
  });
  
  bool _shouldRetry() {
    return _error != _noError && _attempt <= retries;
  }
  
  Object? get error {
    if (_error == _noError) {
      return null;
    }
    return _error;
  }
  
  set error(Object? value) {
    _error = value ?? _noError;
  }
  
  int get attempt => _attempt;
  
  /// Iterate over retry attempts
  Stream<RetryManager> get stream async* {
    while (_shouldRetry()) {
      _error = _noError;
      _attempt++;
      yield this;
      
      if (_error != null && _error != _noError) {
        if (onRetry != null) {
          onRetry!(_error!, _attempt, retries);
        }
        
        // Sleep before retry if sleep function is provided
        if (sleepFunction != null && _attempt <= retries) {
          final delay = sleepFunction!(_attempt);
          if (delay.inMilliseconds > 0) {
            logger.info('retry_manager', 
                'Sleeping ${delay.inSeconds}.${delay.inMilliseconds % 1000} seconds before retry...');
            await Future.delayed(delay);
          }
        }
      }
    }
    
    // If we exhausted retries and error is set, report it
    if (_error != null && _error != _noError && _attempt > retries) {
      if (fatal) {
        throw _error!;
      } else {
        logger.warning('retry_manager', 
            '${_error}. Giving up after ${_attempt - 1} retries');
      }
    }
  }
  
  /// Synchronous iteration support (for simple cases)
  Iterable<RetryManager> get iterable sync* {
    while (_shouldRetry()) {
      _error = _noError;
      _attempt++;
      yield this;
      
      if (_error != null && _error != _noError) {
        if (onRetry != null) {
          onRetry!(_error!, _attempt, retries);
        }
      }
    }
    
    // If we exhausted retries and error is set, report it
    if (_error != null && _error != _noError && _attempt > retries) {
      if (fatal) {
        throw _error!;
      } else {
        logger.warning('retry_manager', 
            '${_error}. Giving up after ${_attempt - 1} retries');
      }
    }
  }
  
  /// Report retry with standard format
  static void reportRetry(
    Object error,
    int count,
    int retries, {
    Duration Function(int n)? sleepFunc,
    Function(String)? info,
    Function(String)? warn,
    Function(String)? errorFunc,
    String? suffix,
  }) {
    if (count > retries) {
      final message = count > 1 
          ? '${error}. Giving up after ${count - 1} retries'
          : error.toString();
      if (errorFunc != null) {
        errorFunc(message);
      } else {
        throw error is Exception ? error : Exception(message);
      }
      return;
    }
    
    if (count == 0) {
      if (warn != null) {
        warn(error.toString());
      }
      return;
    }
    
    final errorMessage = error.toString();
    final suffixStr = suffix != null ? ' $suffix' : '';
    if (warn != null) {
      warn('$errorMessage. Retrying$suffixStr ($count/$retries)...');
    }
    
    if (sleepFunc != null) {
      final delay = sleepFunc(count - 1);
      if (delay.inMilliseconds > 0) {
        final seconds = delay.inSeconds;
        final milliseconds = delay.inMilliseconds % 1000;
        if (info != null) {
          info('Sleeping $seconds.${milliseconds.toString().padLeft(3, '0')} seconds ...');
        }
      }
    }
  }
  
  /// Default exponential backoff sleep function
  static Duration exponentialBackoff(int n, {Duration baseDelay = const Duration(seconds: 1)}) {
    // Exponential backoff: baseDelay * 2^n, capped at 60 seconds
    final delaySeconds = baseDelay.inSeconds * (1 << n);
    return Duration(seconds: delaySeconds > 60 ? 60 : delaySeconds);
  }
  
  /// Linear backoff sleep function
  static Duration linearBackoff(int n, {Duration baseDelay = const Duration(seconds: 1)}) {
    return Duration(seconds: baseDelay.inSeconds * (n + 1));
  }
  
  /// Fixed delay sleep function
  static Duration fixedDelay(int n, {Duration delay = const Duration(seconds: 1)}) {
    return delay;
  }
}

class _NoError {
  const _NoError();
}
