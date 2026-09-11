// main.c
// ESP32‑S3 firmware skeleton for audio capture (PCM1808),
// distribution to 10 mono outputs (5 × PCM5102) and remote control via Ethernet (W5500).
// Uses ESP‑IDF framework.

#include "esp_system.h"
#include "esp_log.h"
#include "driver/i2s.h"
#include "driver/i2c.h"
#include "driver/spi_master.h"
#include "driver/gpio.h"
#include "esp_http_server.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"

#define TAG "audio_sys"

// ---------- Configuration ----------
// I2S configuration (RX from PCM1808)
#define I2S_RX_NUM   (0)
#define I2S_RX_SAMPLE_RATE (48000)
#define I2S_RX_BIT_DEPTH   (24)

// I2S configuration (TX to PCM5102, TDM 10 slots)
#define I2S_TX_NUM   (1)
#define I2S_TX_SAMPLE_RATE (48000)
#define I2S_TX_BIT_DEPTH   (24)
#define I2S_TX_TDM_SLOTS   (10)

// I2C configuration for PCM5102 control
#define I2C_MASTER_NUM   I2C_NUM_0
#define I2C_MASTER_SCL_IO 22
#define I2C_MASTER_SDA_IO 21
#define I2C_MASTER_FREQ_HZ 200000

// SPI configuration for W5500
#define SPI_HOST    HSPI_HOST
#define PIN_NUM_MISO 19
#define PIN_NUM_MOSI 23
#define PIN_NUM_SCLK 18
#define PIN_NUM_CS   5   // CS for W5502

// GPIO pins for mute/standby (DEEM) – one per channel (10 pins)
static const gpio_num_t mute_gpio[10] = { 
    GPIO_NUM_2,  GPIO_NUM_4,  GPIO_NUM_12, GPIO_NUM_13, GPIO_NUM_14,
    GPIO_NUM_15, GPIO_NUM_25, GPIO_NUM_26, GPIO_NUM_27, GPIO_NUM_32
};

// Queue for commands received via Ethernet
static QueueHandle_t cmd_queue;

typedef struct {
    uint8_t channel; // 0‑9
    uint8_t volume;  // 0‑255
    bool mute;       // true = mute
} channel_cmd_t;

// ---------- I2C Helper ----------
static esp_err_t i2c_write_reg(uint8_t dev_addr, uint8_t reg_addr, uint8_t data)
{
    i2c_cmd_handle_t cmd = i2c_cmd_link_create();
    i2c_master_start(cmd);
    i2c_master_write_byte(cmd, (dev_addr << 1) | I2C_MASTER_WRITE, true);
    i2c_master_write_byte(cmd, reg_addr, true);
    i2c_master_write_byte(cmd, data, true);
    i2c_master_stop(cmd);
    esp_err_t ret = i2c_master_cmd_begin(I2C_MASTER_NUM, cmd, pdMS_TO_TICKS(1000));
    i2c_cmd_link_delete(cmd);
    return ret;
}

// Set volume for a specific PCM5102 channel (each channel has its own I2C address)
static void set_volume(uint8_t address, uint8_t volume)
{
    // PCM5102 volume register is 0x02 (0 = mute, 255 = max)
    i2c_write_reg(address, 0x02, volume);
}

// ---------- Mute GPIO ----------
static void set_mute(uint8_t ch, bool mute)
{
    gpio_set_level(mute_gpio[ch], mute ? 1 : 0); // DEEM pin active‑high for mute
}

// ---------- I2S Initialization ----------
static void i2s_rx_init(void)
{
    i2s_config_t i2s_config = {
        .mode = I2S_MODE_MASTER | I2S_MODE_RX,
        .sample_rate = I2S_RX_SAMPLE_RATE,
        .bits_per_sample = I2S_BITS_PER_SAMPLE_24BIT,
        .channel_format = I2S_CHANNEL_FMT_ONLY_RIGHT, // mono from PCM1808
        .communication_format = I2S_COMM_FORMAT_STAND_MSB,
        .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
        .dma_buf_count = 4,
        .dma_buf_len = 256,
        .use_apll = false,
        .tx_desc_auto_clear = false,
        .fixed_mclk = 0
    };
    i2s_pin_config_t pin_cfg = {
        .bck_io_num = 26,   // BCLK from PCM1808
        .ws_io_num = 25,    // LRCK
        .data_out_num = I2S_PIN_NO_CHANGE,
        .data_in_num = 27   // DOUT from PCM1808
    };
    ESP_ERROR_CHECK(i2s_driver_install(I2S_RX_NUM, &i2s_config, 0, NULL));
    ESP_ERROR_CHECK(i2s_set_pin(I2S_RX_NUM, &pin_cfg));
}

static void i2s_tx_init(void)
{
    i2s_config_t i2s_config = {
        .mode = I2S_MODE_MASTER | I2S_MODE_TX,
        .sample_rate = I2S_TX_SAMPLE_RATE,
        .bits_per_sample = I2S_BITS_PER_SAMPLE_24BIT,
        .channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT, // TDM will be configured later
        .communication_format = I2S_COMM_FORMAT_STAND_MSB,
        .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
        .dma_buf_count = 4,
        .dma_buf_len = 256,
        .use_apll = false,
        .tx_desc_auto_clear = true,
        .fixed_mclk = 0
    };
    i2s_pin_config_t pin_cfg = {
        .bck_io_num = 14,   // shared BCLK for PCM5102
        .ws_io_num = 15,    // shared LRCK (single slot, ignored by TDM)
        .data_out_num = 16, // DATA out to PCM5102s (TDM line)
        .data_in_num = I2S_PIN_NO_CHANGE
    };
    ESP_ERROR_CHECK(i2s_driver_install(I2S_TX_NUM, &i2s_config, 0, NULL));
    ESP_ERROR_CHECK(i2s_set_pin(I2S_TX_NUM, &pin_cfg));

    // Enable TDM mode with 10 slots (ESP‑IDF 5.0+ supports i2s_set_clk)
    i2s_set_clk(I2S_TX_NUM, I2S_TX_SAMPLE_RATE, I2S_BITS_PER_SAMPLE_24BIT, I2S_CHANNEL_MONO);
    // Note: Real TDM configuration may require using the I2S peripheral’s built‑in TDM support;
    // this skeleton leaves the detailed register tweaking as an implementation task.
}

// ---------- SPI (W5500) ----------
static void spi_init(void)
{
    spi_bus_config_t buscfg = {
        .miso_io_num = PIN_NUM_MISO,
        .mosi_io_num = PIN_NUM_MOSI,
        .sclk_io_num = PIN_NUM_SCLK,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = 4096
    };
    ESP_ERROR_CHECK(spi_bus_initialize(SPI_HOST, &buscfg, SPI_DMA_CH_AUTO));

    spi_device_interface_config_t devcfg = {
        .clock_speed_hz = 10 * 1000 * 1000, // 10 MHz
        .mode = 0,
        .spics_io_num = PIN_NUM_CS,
        .queue_size = 4,
    };
    spi_device_handle_t spi;
    ESP_ERROR_CHECK(spi_bus_add_device(SPI_HOST, &devcfg, &spi));
    // W5500 driver would be added here (e.g., using the open‑source w5500_esp_idf component)
}

// ---------- HTTP Server ----------
static esp_err_t volume_put_handler(httpd_req_t *req)
{
    // Expected URL: /channel/<id>/volume
    char uri[64];
    httpd_req_get_url_req(req, uri, sizeof(uri));
    // Simple parsing – production code should be more robust
    int channel = -1;
    if (sscanf(uri, "/channel/%d/volume", &channel) != 1 || channel < 0 || channel > 9) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Invalid channel");
        return ESP_FAIL;
    }
    // Read JSON payload {"value":128}
    char body[64];
    int received = httpd_req_recv(req, body, sizeof(body)-1);
    if (received <= 0) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "No body");
        return ESP_FAIL;
    }
    body[received] = '\0';
    int vol = -1;
    if (sscanf(body, "{\"value\":%d}", &vol) != 1 || vol < 0 || vol > 255) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Invalid JSON");
        return ESP_FAIL;
    }
    channel_cmd_t cmd = {.channel = channel, .volume = (uint8_t)vol, .mute = false};
    xQueueSend(cmd_queue, &cmd, pdMS_TO_TICKS(100));
    httpd_resp_sendstr(req, "OK");
    return ESP_OK;
}

static esp_err_t mute_put_handler(httpd_req_t *req)
{
    char uri[64];
    httpd_req_get_url_req(req, uri, sizeof(uri));
    int channel = -1;
    if (sscanf(uri, "/channel/%d/mute", &channel) != 1 || channel < 0 || channel > 9) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Invalid channel");
        return ESP_FAIL;
    }
    char body[64];
    int received = httpd_req_recv(req, body, sizeof(body)-1);
    if (received <= 0) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "No body");
        return ESP_FAIL;
    }
    body[received] = '\0';
    int mute = -1;
    if (sscanf(body, "{\"state\":%d}", &mute) != 1 || (mute != 0 && mute != 1)) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Invalid JSON");
        return ESP_FAIL;
    }
    channel_cmd_t cmd = {.channel = channel, .volume = 0, .mute = (bool)mute};
    xQueueSend(cmd_queue, &cmd, pdMS_TO_TICKS(100));
    httpd_resp_sendstr(req, "OK");
    return ESP_OK;
}

static const httpd_uri_t volume_uri = {
    .uri      = "/channel/*/volume",
    .method   = HTTP_PUT,
    .handler  = volume_put_handler,
    .user_ctx = NULL
};
static const httpd_uri_t mute_uri = {
    .uri      = "/channel/*/mute",
    .method   = HTTP_PUT,
    .handler  = mute_put_handler,
    .user_ctx = NULL
};

static void start_webserver(void)
{
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    httpd_handle_t server = NULL;
    ESP_ERROR_CHECK(httpd_start(&server, &config));
    httpd_register_uri_handler(server, &volume_uri);
    httpd_register_uri_handler(server, &mute_uri);
    ESP_LOGI(TAG, "HTTP server started");
}

// ---------- Audio Processing Task ----------
static void audio_task(void *arg)
{
    size_t bytes_read;
    uint8_t rx_buf[256 * 3]; // 24‑bit = 3 bytes per sample
    uint8_t tx_buf[256 * 3 * 10]; // TDM buffer for 10 channels

    while (1) {
        // Read a block from PCM1808
        esp_err_t err = i2s_read(I2S_RX_NUM, rx_buf, sizeof(rx_buf), &bytes_read, pdMS_TO_TICKS(1000));
        if (err != ESP_OK || bytes_read == 0) continue;

        // Simple demultiplex: replicate the same sample to all 10 slots (synchronised playback)
        size_t samples = bytes_read / 3; // 24‑bit samples
        for (size_t s = 0; s < samples; ++s) {
            uint8_t *src = &rx_buf[s * 3];
            for (int ch = 0; ch < 10; ++ch) {
                uint8_t *dst = &tx_buf[(s * 10 + ch) * 3];
                dst[0] = src[0];
                dst[1] = src[1];
                dst[2] = src[2];
            }
        }
        // Write TDM frame to PCM5102s
        size_t bytes_written;
        i2s_write(I2S_TX_NUM, tx_buf, sizeof(tx_buf), &bytes_written, pdMS_TO_TICKS(1000));
    }
    vTaskDelete(NULL);
}

// ---------- Command Processing Task ----------
static void cmd_task(void *arg)
{
    channel_cmd_t cmd;
    while (1) {
        if (xQueueReceive(cmd_queue, &cmd, pdMS_TO_TICKS(100))) {
            // Determine I2C address for the given channel.
            // Assuming each PCM5102 provides two addresses (A0 low/high). For example:
            // address = 0x4C + (channel / 2) + ((channel % 2) ? 1 : 0)
            uint8_t dev_addr = 0x4C + (cmd.channel / 2) + ((cmd.channel % 2) ? 1 : 0);
            if (cmd.mute) {
                set_mute(cmd.channel, true);
            } else {
                set_mute(cmd.channel, false);
                set_volume(dev_addr, cmd.volume);
            }
            ESP_LOGI(TAG, "Channel %d: vol=%d mute=%d", cmd.channel, cmd.volume, cmd.mute);
        }
    }
    vTaskDelete(NULL);
}

void app_main(void)
{
    ESP_LOGI(TAG, "Starting audio system");
    // Initialise peripherals
    i2s_rx_init();
    i2s_tx_init();
    spi_init();

    // Initialise I2C master
    i2c_config_t i2c_conf = {
        .mode = I2C_MODE_MASTER,
        .sda_io_num = I2C_MASTER_SDA_IO,
        .scl_io_num = I2C_MASTER_SCL_IO,
        .sda_pullup_en = GPIO_PULLUP_ENABLE,
        .scl_pullup_en = GPIO_PULLUP_ENABLE,
        .master = {.clk_speed = I2C_MASTER_FREQ_HZ},
        .clk_flags = 0,
    };
    ESP_ERROR_CHECK(i2c_param_config(I2C_MASTER_NUM, &i2c_conf));
    ESP_ERROR_CHECK(i2c_driver_install(I2C_MASTER_NUM, i2c_conf.mode, 0, 0, 0));

    // Initialise mute GPIOs
    for (int i = 0; i < 10; ++i) {
        gpio_config_t io_conf = {
            .pin_bit_mask = (1ULL << mute_gpio[i]),
            .mode = GPIO_MODE_OUTPUT,
            .pull_up_en = GPIO_PULLUP_DISABLE,
            .pull_down_en = GPIO_PULLDOWN_DISABLE,
            .intr_type = GPIO_INTR_DISABLE,
        };
        gpio_config(&io_conf);
        gpio_set_level(mute_gpio[i], 0); // un‑mute by default
    }

    // Create command queue
    cmd_queue = xQueueCreate(20, sizeof(channel_cmd_t));

    // Start tasks
    xTaskCreatePinnedToCore(audio_task, "audio_task", 4096, NULL, 5, NULL, 0);
    xTaskCreatePinnedToCore(cmd_task, "cmd_task", 2048, NULL, 5, NULL, 0);

    // Start Ethernet (W5500) and HTTP server – network init omitted for brevity
    // Assume Wi‑Fi credentials are configured elsewhere.
    start_webserver();
}
