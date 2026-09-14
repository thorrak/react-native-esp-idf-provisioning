const mockCreateESPDevice = jest.fn().mockResolvedValue({});
const mockConnect = jest.fn().mockResolvedValue({ status: 'connected' });
const mockSendData = jest.fn();
const mockDisconnect = jest.fn();
const mockRemove = jest.fn();
const mockAddListener = jest.fn().mockReturnValue({ remove: mockRemove });

jest.mock('react-native', () => ({
  NativeEventEmitter: jest
    .fn()
    .mockImplementation(() => ({ addListener: mockAddListener })),
  NativeModules: {
    EspIdfProvisioning: {
      createESPDevice: mockCreateESPDevice,
      connect: mockConnect,
      sendData: mockSendData,
      disconnect: mockDisconnect,
    },
  },
  Platform: {
    select: jest.fn((options) => options.default),
  },
}));

describe('ESPDevice.connect', () => {
  beforeEach(() => {
    mockCreateESPDevice.mockClear();
    mockConnect.mockClear();
    mockSendData.mockClear();
  });

  it('normalizes a missing PoP to empty string for security 0 devices', async () => {
    const { ESPDevice, ESPSecurity, ESPTransport } = require('../index');

    const device = new ESPDevice({
      name: 'PROV_123',
      transport: ESPTransport.ble,
      security: ESPSecurity.unsecure,
    });

    await device.connect(undefined, null, null);

    expect(mockCreateESPDevice).toHaveBeenCalledWith(
      'PROV_123',
      ESPTransport.ble,
      ESPSecurity.unsecure,
      '',
      null,
      null
    );
  });

  it('keeps PoP null for secure devices', async () => {
    const { ESPDevice, ESPSecurity, ESPTransport } = require('../index');

    const device = new ESPDevice({
      name: 'PROV_456',
      transport: ESPTransport.ble,
      security: ESPSecurity.secure,
    });

    await device.connect(null, null, null);

    expect(mockCreateESPDevice).toHaveBeenCalledWith(
      'PROV_456',
      ESPTransport.ble,
      ESPSecurity.secure,
      null,
      null,
      null
    );
  });

  it('rejects secure2 devices without a proof of possession', async () => {
    const { ESPDevice, ESPSecurity, ESPTransport } = require('../index');

    const device = new ESPDevice({
      name: 'PROV_789',
      transport: ESPTransport.ble,
      security: ESPSecurity.secure2,
    });

    await expect(device.connect(null, null, 'user')).rejects.toThrow(
      'Proof of possession is required for devices using ESPSecurity.secure2.'
    );

    expect(mockCreateESPDevice).not.toHaveBeenCalled();
  });

  it('rejects secure2 devices without a username', async () => {
    const { ESPDevice, ESPSecurity, ESPTransport } = require('../index');

    const device = new ESPDevice({
      name: 'PROV_999',
      transport: ESPTransport.ble,
      security: ESPSecurity.secure2,
    });

    await expect(device.connect('pop', null, null)).rejects.toThrow(
      'Username is required for devices using ESPSecurity.secure2.'
    );

    expect(mockCreateESPDevice).not.toHaveBeenCalled();
  });
});

describe('ESPDevice.sendData', () => {
  beforeEach(() => {
    mockSendData.mockClear();
  });

  it('adds session guidance when custom endpoint requests fail', async () => {
    const { ESPDevice, ESPSecurity, ESPTransport } = require('../index');

    mockSendData.mockRejectedValueOnce(new Error('Write to BLE failed'));

    const device = new ESPDevice({
      name: 'PROV_SEND',
      transport: ESPTransport.ble,
      security: ESPSecurity.secure2,
    });

    await expect(
      device.sendData('/custom-endpoint', '{"foo":"bar"}')
    ).rejects.toThrow(
      'Request to send data to device failed: Write to BLE failed. Custom endpoint requests require an active provisioning session; if this happens after provision(), the device firmware may have already closed the session or disconnected the transport.'
    );
  });
});

describe('connection cancellation', () => {
  beforeEach(() => {
    mockConnect.mockClear();
    mockDisconnect.mockClear();
  });

  it('does not connect if cancellation happens during native device discovery', async () => {
    const { ESPDevice, ESPSecurity, ESPTransport } = require('../index');
    let finishDiscovery!: (value: object) => void;
    mockCreateESPDevice.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finishDiscovery = resolve;
        })
    );
    const device = new ESPDevice({
      name: 'TiltBridge_1',
      transport: ESPTransport.ble,
      security: ESPSecurity.secure,
    });
    const pending = device.connect('pop');
    device.disconnect();
    finishDiscovery({});
    await expect(pending).rejects.toMatchObject({
      code: 'operation_cancelled',
    });
    expect(mockDisconnect).toHaveBeenCalledWith('TiltBridge_1');
    expect(mockConnect).not.toHaveBeenCalled();
  });

  it('does not report success from a cancelled native handshake', async () => {
    const { ESPDevice, ESPSecurity, ESPTransport } = require('../index');
    let finishConnect!: (value: object) => void;
    mockConnect.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finishConnect = resolve;
        })
    );
    const device = new ESPDevice({
      name: 'TiltBridge_2',
      transport: ESPTransport.ble,
      security: ESPSecurity.secure,
    });
    const pending = device.connect('pop');
    await Promise.resolve();
    device.disconnect();
    finishConnect({ status: 'connected' });
    await expect(pending).rejects.toMatchObject({
      code: 'operation_cancelled',
    });
  });

  it('preserves a structured session failure without calling it bad credentials', async () => {
    const { ESPDevice, ESPSecurity, ESPTransport } = require('../index');
    mockConnect.mockRejectedValueOnce(
      Object.assign(new Error('Failed to initialise session with the device'), {
        code: 'session_init_failed',
      })
    );
    const device = new ESPDevice({
      name: 'TiltBridge_3',
      transport: ESPTransport.ble,
      security: ESPSecurity.secure,
    });
    await expect(device.connect('pop')).rejects.toMatchObject({
      code: 'session_init_failed',
    });
  });
});

describe('device disconnection events', () => {
  it('subscribes to the native event with device identity and returns cleanup', () => {
    const { addDeviceDisconnectListener } = require('../index');
    const listener = jest.fn();
    const unsubscribe = addDeviceDisconnectListener(listener);
    expect(mockAddListener).toHaveBeenCalledWith(
      'EspIdfProvisioningDeviceDisconnected',
      listener
    );
    const nativeListener = mockAddListener.mock.calls.at(-1)[1];
    nativeListener({
      deviceName: 'TiltBridge_1',
      reason: 'Device disconnected.',
    });
    expect(listener).toHaveBeenCalledWith({
      deviceName: 'TiltBridge_1',
      reason: 'Device disconnected.',
    });
    unsubscribe();
    expect(mockRemove).toHaveBeenCalled();
  });
});
