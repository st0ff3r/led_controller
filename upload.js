var source; // Global variable for EventSource
var isUploading = false; // Track if the client is actively pushing a file payload
var errorDisplayUntil = 0; // Timestamp lock to force errors to stay visible

function _(element) {
	return document.getElementById(element);
}

_('upload_link').onclick = function(event) {
	_('file_input').click();
};

// Initialize on page load to check for existing status
window.addEventListener('load', function() {
	initProgressTracking();
});

function initProgressTracking() {
	// Clean up any stale or lingering connections before spawning a new one
	if (source) {
		console.log("[SSE] Cleaning up old connection instance...");
		source.close();
	}

	console.log("[SSE] Opening fresh progress listener connection...");
	source = new EventSource('progress');

	source.addEventListener('error', function(event) {
		console.log("[SSE Error] Connection dropped or encountered an error. Closing handle.");
		source.close();
	});

	source.addEventListener('message', function(event) {
		updateUI(event.data);
	}, false);
}

function updateUI(data) {
	console.log("Status update: " + data);
	
	// FIXED: If we are inside the 3-second error display lock, ignore incoming progress updates completely
	if (Date.now() < errorDisplayUntil) {
		console.log("[UI Lock] Ignoring server message while error message is displayed.");
		return;
	}

	// Fast flags
	if (data == "0.0") {
		// FIXED: Only hide the progress bar if the user isn't actively uploading a file right now
		if (!isUploading) {
			resetProgressBar();
		}
		return;
	} 
	if (data == "ERROR") {
		showUploadError('<div class="alert alert-danger w-100 m-0 h-100 d-flex align-items-center justify-content-center" style="font-weight: bold;">Server side processing failed</div>');
		return;
	}

	var numeric_val = parseFloat(data);
	if (isNaN(numeric_val)) return;

	// Catch the sentinel value -1.0 to handle the completion state
	if (numeric_val === -1.0) {
		console.log("[UI Completing] Sentinel -1.0 encountered. Closing SSE channel.");
		if (source) {
			source.close(); 
		}

		ensureProgressBarStructure();
		_('progress_bar').style.display = 'block';
		_('progress_bar_process').className = 'progress-bar bg-success'; 
		_('progress_bar_process').style.width = '100%';
		_('progress_bar_process').innerHTML = 'Ready';
		
		setTimeout(function() {
			resetProgressBar();
			_('slitscan').src = 'images/slitscan.png?' + Date.now();
		}, 1500);
		return;
	}

	var percent_completed = Math.round(numeric_val);

	if (percent_completed >= 50) {
		ensureProgressBarStructure();
		_('progress_bar').style.display = 'block';
		_('progress_bar_process').className = 'progress-bar bg-success'; 
		_('progress_bar_process').style.width = percent_completed + '%';
		_('progress_bar_process').innerHTML = 'Processing ' + percent_completed + '%';
	}
}

// Trigger hidden file input
_('drag_drop').onclick = function(event) {
	if (event.target.id === 'drag_drop' || event.target.tagName === 'DIV') {
		_('file_input').click();
	}
};

_('file_input').onchange = function(event) {
	var select_files = event.target.files;
	if (select_files.length > 0) {
		handleFileUpload(select_files[0]);
	}
};

// Drag and Drop event handlers
_('drag_drop').ondragover = function(event) {
	event.preventDefault();
	this.style.borderColor = '#333';
	return false;
};

_('drag_drop').ondragleave = function(event) {
	this.style.borderColor = '#ccc';
	return false;
};

_('drag_drop').ondrop = function(event) {
	event.preventDefault();
	var drop_files = event.dataTransfer.files;
	if (drop_files.length <= 1) {
		handleFileUpload(drop_files[0]);
	} else {
		showUploadError('<div class="alert alert-danger w-100 m-0 h-100 d-flex align-items-center justify-content-center" style="font-weight: bold;">Only supports upload of one file</div>');
	}
};

function handleFileUpload(file) {
	// 1. Client-side Size Check
	if (file.size > 500 * 1024 * 1024) {
		showUploadError('<div class="alert alert-danger w-100 m-0 h-100 d-flex align-items-center justify-content-center" style="font-weight: bold;">File is too large (max 500MB)</div>');
		return;
	}

	// 2. Pre-flight check (HEAD request)
	var check_request = new XMLHttpRequest();
	check_request.open("HEAD", "upload");
	check_request.onload = function() {
		if (check_request.status === 403) {
			showUploadError('<div class="alert alert-danger w-100 m-0 h-100 d-flex align-items-center justify-content-center" style="font-weight: bold;">System already running a job</div>');
		} else {
			performActualUpload(file);
		}
	};
	check_request.send();
}

function performActualUpload(file) {
	// Smooth scroll to top IMMEDIATELY before the progress bar initiates or drops in
	window.scrollTo({ top: 0, behavior: 'smooth' });

	var form_data = new FormData();
	form_data.append("movie_file", file);

	// Set upload state flag to stop incoming 0.0 server messages from clearing our bar out
	isUploading = true;

	// Force a fresh, clear SSE subscription link to start listening right as the upload initiates
	initProgressTracking();
	ensureProgressBarStructure();

	_('progress_bar').style.display = 'block';
	var ajax_request = new XMLHttpRequest();
	ajax_request.open("post", "upload");

	// Map Upload (0-100% of file) to UI (0-50% of bar)
	ajax_request.upload.addEventListener('progress', function(event) {
		if (event.lengthComputable && Date.now() >= errorDisplayUntil) {
			ensureProgressBarStructure();
			var bar_percent = Math.round((event.loaded / event.total) * 50);
			
			_('progress_bar_process').style.width = bar_percent + '%';
			_('progress_bar_process').innerHTML = 'Uploading ' + bar_percent + '%';
		}
	});

	ajax_request.addEventListener('load', function(event) {
		isUploading = false; // Reset state flag on load resolution

		// FIXED: Check lock timer status before resolving the request layout mutations
		if (Date.now() < errorDisplayUntil) return;

		if (ajax_request.status === 413) {
			// Handle the specific backend size rejection
			showUploadError('<div class="alert alert-danger w-100 m-0 h-100 d-flex align-items-center justify-content-center" style="font-weight: bold;">File is too large (Server Rejected)</div>');
		} else if (ajax_request.status >= 400) {
			showUploadError('<div class="alert alert-danger w-100 m-0 h-100 d-flex align-items-center justify-content-center" style="font-weight: bold;">System already running a job</div>');
		} else {
			if (_('progress_bar_process')) {
				_('progress_bar_process').innerHTML = 'Processing...';
			}
		}
	});
	
	ajax_request.send(form_data);
}

// Safety check to rebuild standard bar elements if they were replaced by an error block
function ensureProgressBarStructure() {
	if (!_( 'progress_bar_process' )) {
		_('progress_bar').innerHTML = '<div class="progress-bar bg-success" id="progress_bar_process" role="progressbar" style="width:0%; height:50px;">0%</div>';
	}
}

function resetProgressBar() {
	_('progress_bar').style.display = 'none';
	ensureProgressBarStructure();
	_('progress_bar_process').style.width = '0%';
	_('progress_bar_process').innerHTML = '';
	_('drag_drop').style.borderColor = '#ccc';
	_('file_input').value = ''; 
	isUploading = false;
}

function showUploadError(errorHtmlBlock) {
	// FIXED: Lock out updateUI rendering updates for at least 3 seconds
	errorDisplayUntil = Date.now() + 3000;
	isUploading = false;

	// Only close the SSE stream if the system isn't already busy processing a job.
	if (errorHtmlBlock.indexOf("already running") === -1 && errorHtmlBlock.indexOf("System already running") === -1) {
		if (source) { source.close(); }
	}
	
	// Completely drop internal progress structure and swap with error markup layout
	_('progress_bar').innerHTML = errorHtmlBlock;
	_('progress_bar').style.display = 'block';
	_('drag_drop').style.borderColor = '#ccc';
	
	// Smooth scroll to top so errors are instantly visible if the page layout stretched down
	window.scrollTo({ top: 0, behavior: 'smooth' });
	
	// After 3 seconds, evaluate if we should hide the block or if a live stream has reclaimed it
	setTimeout(function() {
		if (!_( 'progress_bar_process' )) {
			resetProgressBar();
		}
	}, 3000);
}
