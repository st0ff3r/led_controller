var source; // Global variable for EventSource

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
	// Open connection immediately to get current status from server
	source = new EventSource('progress');

	source.addEventListener('error', function(event) {
		console.log("SSE Connection closed or error.");
		source.close();
	});

	source.addEventListener('message', function(event) {
		updateUI(event.data);
	}, false);
}

function updateUI(data) {
	console.log("Status update: " + data);
	
	// Fast flags
	if (data == "0.0") {
		resetProgressBar();
		return;
	} 
	if (data == "ERROR") {
		resetProgressBar();
		showUploadError('<div class="alert alert-danger"><b>server side processing failed</div>');
		return;
	}

	// Parse numeric value safely for floating point updates
	var numeric_val = parseFloat(data);
	if (isNaN(numeric_val)) return;

	var percent_completed = Math.round(numeric_val);

	if (percent_completed >= 100) {
		_('progress_bar').style.display = 'block';
		_('progress_bar_process').style.width = '100%';
		_('progress_bar_process').innerHTML = 'Ready';
		
		// Finalize UI
		setTimeout(function() {
			resetProgressBar();
			_('slitscan').src = 'images/slitscan.png?' + Date.now();
		}, 1500);
	} 
	else if (percent_completed >= 50) {
		// FIXED: Tracks intermediate processing milestones (50% -> 99%) dynamically
		_('progress_bar').style.display = 'block';
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
		showUploadError('<div class="alert alert-danger"><b>only supports upload of one file</div>');
	}
};

function handleFileUpload(file) {
	var form_data = new FormData();
	form_data.append("movie_file", file);

	_('progress_bar').style.display = 'block';
	var ajax_request = new XMLHttpRequest();
	ajax_request.open("post", "upload");

	// Map Upload (0-100% of file) to UI (0-50% of bar)
	ajax_request.upload.addEventListener('progress', function(event) {
		if (event.lengthComputable) {
			var upload_ratio = event.loaded / event.total;
			var bar_percent = Math.round(upload_ratio * 50);
			
			_('progress_bar_process').style.width = bar_percent + '%';
			_('progress_bar_process').innerHTML = 'Uploading ' + bar_percent + '%';
		}
	});

	ajax_request.addEventListener('load', function(event) {
		if (ajax_request.status >= 400) {
			showUploadError('<div class="alert alert-danger"><b>already running</div>');
		} else {
			// Once finished, the EventSource listener will take over 
			// for the server-side processing states (50% -> 100%)
			_('progress_bar_process').innerHTML = 'Processing...';
		}
	});
	
	ajax_request.send(form_data);
}

function resetProgressBar() {
	_('progress_bar').style.display = 'none';
	_('progress_bar_process').style.width = '0%';
	_('progress_bar_process').innerHTML = '';
	_('drag_drop').style.borderColor = '#ccc';
	_('file_input').value = ''; 
}

function showUploadError(errorMessage) {
	_('uploaded_image').style.display = 'block';
	_('uploaded_image').innerHTML = errorMessage;
	_('drag_drop').style.borderColor = '#ccc';
	setTimeout(function() {
		_('uploaded_image').innerHTML = '';
	}, 3000);
}
