// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router02.sol";

/**
 * @title KipuBankV3
 * @author eika
 * @notice DeFi bank that accepts any Uniswap V2 supported token, swaps to USDC, and manages user balances
 * @dev Implements:
 *      - Role-based access control (AccessControl)
 *      - Uniswap V2 integration for automatic token swaps to USDC
 *      - Single-token accounting (USDC only)
 *      - Configurable withdrawal limits and bank capacity
 *      - Reentrancy protection
 *      - All deposits are converted to USDC regardless of input token
 */
contract KipuBankV3 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    //                  CONSTANTS
    

    /// @notice Rol de administrador con permisos completos
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    /// @notice Rol de operador para funciones administrativas diarias
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    
    /// @notice Dirección especial para representar ETH nativo
    address public constant NATIVE_TOKEN = address(0);
    
    /// @notice Decimales de USDC (estándar: 6 decimales)
    uint8 public constant USDC_DECIMALS = 6;

    /*═══════════════════════════════════════════════════════════════════════════
                                IMMUTABLE VARIABLES
    ═══════════════════════════════════════════════════════════════════════════*/

    /// @notice Dirección del token USDC
    address public immutable i_usdcAddress;

    /// @notice Dirección de WETH (Wrapped ETH)
    address public immutable i_wethAddress;

    /// @notice Router de Uniswap V2
    IUniswapV2Router02 public immutable i_uniswapRouter;

    /// @notice Límite máximo de retiro por transacción en USDC (6 decimales)
    uint256 public immutable i_withdrawalThresholdUSDC;

    /// @notice Límite global del banco en USDC (6 decimales)
    uint256 public immutable i_bankCapUSDC;

    /*═══════════════════════════════════════════════════════════════════════════
                                STATE VARIABLES
    ═══════════════════════════════════════════════════════════════════════════*/

    /// @notice Balance total depositado en USDC (suma de todos los usuarios)
    uint256 private s_totalDepositsUSDC;

    /// @notice Contador total de depósitos realizados
    uint256 private s_depositCount;

    /// @notice Contador total de retiros realizados
    uint256 private s_withdrawalCount;

    /// @notice Mapeo de dirección de usuario a su balance en USDC
    mapping(address => uint256) private s_vaults;

    /*═══════════════════════════════════════════════════════════════════════════
                                CUSTOM ERRORS
    ═══════════════════════════════════════════════════════════════════════════*/

    error KipuBank__AmountMustBeGreaterThanZero();
    error KipuBank__DepositExceedsBankCap();
    error KipuBank__InsufficientBalance();
    error KipuBank__WithdrawalExceedsThreshold();
    error KipuBank__TransferFailed();
    error KipuBank__InvalidAddress();
    error KipuBank__SwapFailed();
    error KipuBank__ZeroUsdcReceived();
    error KipuBank__CannotDepositUsdcAsToken();

    /*═══════════════════════════════════════════════════════════════════════════
                                    EVENTS
    ═══════════════════════════════════════════════════════════════════════════*/

    /**
     * @notice Evento emitido cuando un usuario deposita ETH o tokens (convertidos a USDC)
     * @param user Dirección del usuario que deposita
     * @param tokenIn Dirección del token depositado (address(0) para ETH)
     * @param amountIn Cantidad depositada en el token original
     * @param usdcReceived Cantidad de USDC recibida después del swap
     * @param newBalance Nuevo balance total del usuario en USDC
     */
    event Deposit(
        address indexed user,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 usdcReceived,
        uint256 newBalance
    );

    /**
     * @notice Evento emitido cuando un usuario retira USDC
     * @param user Dirección del usuario que retira
     * @param amount Cantidad retirada en USDC
     * @param remainingBalance Balance restante del usuario en USDC
     */
    event Withdrawal(
        address indexed user,
        uint256 amount,
        uint256 remainingBalance
    );

    /*═══════════════════════════════════════════════════════════════════════════
                                    MODIFIERS
    ═══════════════════════════════════════════════════════════════════════════*/

    /// @notice Verifica que el monto sea mayor que cero
    modifier nonZeroAmount(uint256 amount) {
        if (amount == 0) revert KipuBank__AmountMustBeGreaterThanZero();
        _;
    }

    /// @notice Verifica que el usuario tenga suficiente balance
    modifier hasSufficientBalance(uint256 amount) {
        if (s_vaults[msg.sender] < amount) {
            revert KipuBank__InsufficientBalance();
        }
        _;
    }

    /*═══════════════════════════════════════════════════════════════════════════
                                    CONSTRUCTOR
    ═══════════════════════════════════════════════════════════════════════════*/

    /**
     * @notice Inicializa KipuBank V3
     * @param uniswapRouter Dirección del Uniswap V2 Router
     * @param wethAddress Dirección del token WETH
     * @param usdcAddress Dirección del token USDC
     * @param withdrawalThresholdUSDC Límite de retiro por transacción en USDC (6 decimales)
     * @param bankCapUSDC Límite total del banco en USDC (6 decimales)
     */
    constructor(
        address uniswapRouter,
        address wethAddress,
        address usdcAddress,
        uint256 withdrawalThresholdUSDC,
        uint256 bankCapUSDC
    ) {
        if (uniswapRouter == address(0)) revert KipuBank__InvalidAddress();
        if (wethAddress == address(0)) revert KipuBank__InvalidAddress();
        if (usdcAddress == address(0)) revert KipuBank__InvalidAddress();
        if (withdrawalThresholdUSDC == 0) revert KipuBank__AmountMustBeGreaterThanZero();
        if (bankCapUSDC == 0) revert KipuBank__AmountMustBeGreaterThanZero();

        i_uniswapRouter = IUniswapV2Router02(uniswapRouter);
        i_wethAddress = wethAddress;
        i_usdcAddress = usdcAddress;
        i_withdrawalThresholdUSDC = withdrawalThresholdUSDC;
        i_bankCapUSDC = bankCapUSDC;

        // Configurar roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /*═══════════════════════════════════════════════════════════════════════════
                                RECEIVE FUNCTION
    ═══════════════════════════════════════════════════════════════════════════*/

    /**
     * @notice Función receive para aceptar ETH directo y convertirlo a depósito
     * @dev Llama automáticamente a depositNative()
     */
    receive() external payable {
        depositNative();
    }

    /*═══════════════════════════════════════════════════════════════════════════
                                DEPOSIT FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════════*/

    /**
     * @notice Deposita ETH nativo y lo convierte a USDC vía Uniswap V2
     * @dev El ETH se swapea automáticamente a USDC y se acredita al balance del usuario
     */
    function depositNative()
        public
        payable
        nonZeroAmount(msg.value)
        nonReentrant
    {
        uint256 amountIn = msg.value;
        address user = msg.sender;

        // Preparar path: ETH -> WETH -> USDC
        address[] memory path = new address[](2);
        path[0] = i_wethAddress;
        path[1] = i_usdcAddress;

        // Obtener balance de USDC antes del swap
        uint256 usdcBefore = IERC20(i_usdcAddress).balanceOf(address(this));

        // Ejecutar swap en Uniswap V2
        try i_uniswapRouter.swapExactETHForTokens{value: amountIn}(
            0, // amountOutMin = 0 (en producción usar slippage protection)
            path,
            address(this),
            block.timestamp
        ) {
            // Calcular USDC recibido
            uint256 usdcAfter = IERC20(i_usdcAddress).balanceOf(address(this));
            uint256 usdcReceived = usdcAfter - usdcBefore;

            if (usdcReceived == 0) revert KipuBank__ZeroUsdcReceived();

            // Verificar que no se exceda el bank cap
            if (s_totalDepositsUSDC + usdcReceived > i_bankCapUSDC) {
                revert KipuBank__DepositExceedsBankCap();
            }

            // Actualizar estado
            s_vaults[user] += usdcReceived;
            s_totalDepositsUSDC += usdcReceived;
            s_depositCount++;

            emit Deposit(user, NATIVE_TOKEN, amountIn, usdcReceived, s_vaults[user]);

        } catch {
            // Si el swap falla, devolver ETH al usuario
            (bool sent, ) = payable(user).call{value: amountIn}("");
            if (!sent) revert KipuBank__TransferFailed();
            revert KipuBank__SwapFailed();
        }
    }

    /**
     * @notice Deposita tokens ERC20 y los convierte a USDC vía Uniswap V2
     * @dev Si el token es USDC, se deposita directamente sin swap
     * @param token Dirección del token ERC20 a depositar
     * @param amount Cantidad de tokens a depositar
     */
    function depositToken(address token, uint256 amount)
        external
        nonZeroAmount(amount)
        nonReentrant
    {
        if (token == NATIVE_TOKEN) revert KipuBank__InvalidAddress();
        
        address user = msg.sender;
        IERC20 tokenIn = IERC20(token);

        // Transferir tokens del usuario al contrato
        tokenIn.safeTransferFrom(user, address(this), amount);

        uint256 usdcReceived;

        // Si el token ES USDC, no hacer swap
        if (token == i_usdcAddress) {
            usdcReceived = amount;
        } else {
            // Aprobar Uniswap para gastar los tokens
            tokenIn.forceApprove(address(i_uniswapRouter), amount);

            // Preparar path: Token -> USDC
            address[] memory path = new address[](2);
            path[0] = token;
            path[1] = i_usdcAddress;

            // Obtener balance de USDC antes del swap
            uint256 usdcBefore = IERC20(i_usdcAddress).balanceOf(address(this));

            // Ejecutar swap
            try i_uniswapRouter.swapExactTokensForTokens(
                amount,
                0, // amountOutMin = 0 (en producción usar slippage protection)
                path,
                address(this),
                block.timestamp
            ) {
                // Calcular USDC recibido
                uint256 usdcAfter = IERC20(i_usdcAddress).balanceOf(address(this));
                usdcReceived = usdcAfter - usdcBefore;

                if (usdcReceived == 0) revert KipuBank__ZeroUsdcReceived();

                // Resetear aprobación por seguridad
                tokenIn.forceApprove(address(i_uniswapRouter), 0);

            } catch {
                // Si falla el swap, devolver tokens al usuario
                tokenIn.safeTransfer(user, amount);
                revert KipuBank__SwapFailed();
            }
        }

        // Verificar que no se exceda el bank cap
        if (s_totalDepositsUSDC + usdcReceived > i_bankCapUSDC) {
            revert KipuBank__DepositExceedsBankCap();
        }

        // Actualizar estado
        s_vaults[user] += usdcReceived;
        s_totalDepositsUSDC += usdcReceived;
        s_depositCount++;

        emit Deposit(user, token, amount, usdcReceived, s_vaults[user]);
    }

    /*═══════════════════════════════════════════════════════════════════════════
                                WITHDRAWAL FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════════*/

    /**
     * @notice Retira USDC de la bóveda del usuario
     * @dev Solo se puede retirar USDC, respetando el límite de retiro
     * @param amount Cantidad de USDC a retirar (6 decimales)
     */
    function withdraw(uint256 amount)
        external
        nonZeroAmount(amount)
        hasSufficientBalance(amount)
        nonReentrant
    {
        // Verificar límite de retiro
        if (amount > i_withdrawalThresholdUSDC) {
            revert KipuBank__WithdrawalExceedsThreshold();
        }

        // Actualizar estado ANTES de la transferencia (CEI pattern)
        s_vaults[msg.sender] -= amount;
        s_totalDepositsUSDC -= amount;
        s_withdrawalCount++;

        uint256 remainingBalance = s_vaults[msg.sender];

        // Transferir USDC al usuario
        IERC20(i_usdcAddress).safeTransfer(msg.sender, amount);

        emit Withdrawal(msg.sender, amount, remainingBalance);
    }

    /*═══════════════════════════════════════════════════════════════════════════
                                ADMIN FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════════*/

    /**
     * @notice Función de emergencia para retirar tokens atascados
     * @dev Solo ADMIN puede llamar esta función
     * @param token Dirección del token a retirar
     * @param amount Cantidad a retirar
     * @param to Dirección destino
     */
    function emergencyWithdraw(address token, uint256 amount, address to)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (to == address(0)) revert KipuBank__InvalidAddress();
        
        if (token == NATIVE_TOKEN) {
            (bool success, ) = payable(to).call{value: amount}("");
            if (!success) revert KipuBank__TransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /*═══════════════════════════════════════════════════════════════════════════
                                VIEW FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════════*/

    /**
     * @notice Obtiene el balance en USDC de un usuario
     * @param user Dirección del usuario
     * @return Balance en USDC (6 decimales)
     */
    function getVaultBalance(address user) external view returns (uint256) {
        return s_vaults[user];
    }

    /**
     * @notice Obtiene el balance en USDC del llamador
     * @return Balance en USDC (6 decimales)
     */
    function getMyVaultBalance() external view returns (uint256) {
        return s_vaults[msg.sender];
    }

    /**
     * @notice Obtiene el balance en USDC del llamador (alias)
     * @return Balance en USDC (6 decimales)
     */
    function getUsdcBalance() external view returns (uint256) {
        return s_vaults[msg.sender];
    }

    /**
     * @notice Obtiene el total de USDC depositado en el banco
     * @return Total en USDC (6 decimales)
     */
    function getTotalDepositsUSDC() external view returns (uint256) {
        return s_totalDepositsUSDC;
    }

    /**
     * @notice Obtiene el total de USDC depositado en el banco (alias para compatibilidad V1)
     * @return Total en USDC (6 decimales)
     */
    function getTotalDeposits() external view returns (uint256) {
        return s_totalDepositsUSDC;
    }

    /**
     * @notice Obtiene el número total de depósitos realizados
     * @return Contador de depósitos
     */
    function getDepositCount() external view returns (uint256) {
        return s_depositCount;
    }

    /**
     * @notice Obtiene el número total de depósitos realizados (alias)
     * @return Contador de depósitos
     */
    function getTotalDepositsCount() external view returns (uint256) {
        return s_depositCount;
    }

    /**
     * @notice Obtiene el número total de retiros realizados
     * @return Contador de retiros
     */
    function getWithdrawalCount() external view returns (uint256) {
        return s_withdrawalCount;
    }

    /**
     * @notice Obtiene el número total de retiros realizados (alias)
     * @return Contador de retiros
     */
    function getTotalWithdrawalsCount() external view returns (uint256) {
        return s_withdrawalCount;
    }

    /**
     * @notice Obtiene la capacidad disponible antes de alcanzar el bankCap
     * @return Espacio disponible en USDC (6 decimales)
     */
    function getAvailableCapacity() external view returns (uint256) {
        return i_bankCapUSDC - s_totalDepositsUSDC;
    }

    /**
     * @notice Obtiene la capacidad disponible antes de alcanzar el bankCap (alias)
     * @return Espacio disponible en USDC (6 decimales)
     */
    function getAvailableCapacityUSDC() external view returns (uint256) {
        return i_bankCapUSDC - s_totalDepositsUSDC;
    }

    /**
     * @notice Obtiene el límite máximo del banco en USDC
     * @return Límite en USDC (6 decimales)
     */
    function getBankCap() external view returns (uint256) {
        return i_bankCapUSDC;
    }

    /**
     * @notice Obtiene el límite máximo de retiro por transacción
     * @return Límite en USDC (6 decimales)
     */
    function getWithdrawalThreshold() external view returns (uint256) {
        return i_withdrawalThresholdUSDC;
    }

    /**
     * @notice Obtiene el balance total de USDC que el contrato mantiene
     * @dev Solo ADMIN puede llamar esta función
     * @return Balance real de USDC en el contrato
     */
    function getTotalBankValueUsdc() external view onlyRole(ADMIN_ROLE) returns (uint256) {
        return IERC20(i_usdcAddress).balanceOf(address(this));
    }

    /**
     * @notice Obtiene la dirección del token USDC
     * @return Dirección de USDC
     */
    function getUsdcAddress() external view returns (address) {
        return i_usdcAddress;
    }

    /**
     * @notice Obtiene la dirección de WETH
     * @return Dirección de WETH
     */
    function getWethAddress() external view returns (address) {
        return i_wethAddress;
    }

    /**
     * @notice Obtiene la dirección del router de Uniswap V2
     * @return Dirección del router
     */
    function getUniswapRouter() external view returns (address) {
        return address(i_uniswapRouter);
    }
}
